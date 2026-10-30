@preconcurrency import CoreBluetooth
import Foundation
import Observation

/// Verbindung zum OBD-Display (ESP32) und alle Daten der App.
///
/// Verbinden (A-CON-01…04): Der ESP32 ist meist schon systemseitig verbunden (HID-Tarnung für die Uhrzeit).
/// Deshalb zuerst `retrieveConnectedPeripherals`, dann das gemerkte Gerät, erst zuletzt ein Scan nach der
/// Service-UUID. Nach einem Abbruch wird sofort ein neuer `connect` gestellt; iOS verbindet, sobald der ESP32
/// wieder erreichbar ist.
///
/// Der `CBCentralManager` läuft auf der Main-Queue, alle Delegate-Aufrufe kommen also auf dem Main-Thread an.
/// Die Delegate-Methoden sind `nonisolated` und springen mit `MainActor.assumeIsolated` zurück.
@MainActor
@Observable
final class OBDLinkManager: NSObject {
    enum ConnectionState: Equatable {
        case bluetoothOff
        case unauthorized
        case searching
        case connecting
        case loading
        case ready
        case incompatible(String)

        var text: String {
            switch self {
            case .bluetoothOff: "Bluetooth ist aus"
            case .unauthorized: "Kein Bluetooth-Zugriff"
            case .searching: "Suche OBD-Display …"
            case .connecting: "Verbinde …"
            case .loading: "Lade Daten …"
            case .ready: "Verbunden"
            case .incompatible(let reason): reason
            }
        }
    }

    struct ValueSample: Sendable {
        var value: Float
        var status: ValueStatus
        var updated: Date
    }

    // MARK: Zustand für die Oberfläche

    private(set) var state: ConnectionState = .searching
    private(set) var deviceInfo: DeviceInfo?
    private(set) var status = DeviceStatus()
    private(set) var catalog: [CatalogEntry] = []
    private(set) var values: [UInt16: ValueSample] = [:]
    private(set) var settings: [UInt8: Data] = [:]
    /// Letzte Rückmeldung je Einstellung (Text)
    private(set) var settingFeedback: [UInt8: String] = [:]
    private(set) var freeDIDs: [FreeDID] = []
    private(set) var rawSamples: [DIDKey: RawSample] = [:]
    private(set) var scanProgress: (header: UInt16, did: UInt16, percent: UInt8)?
    private(set) var scanRunning = false
    private(set) var scanSummary: String?
    let scanStore = ScanStore()
    /// Letzte Fehlermeldung für einen Hinweis in der Oberfläche
    var lastError: String?
    /// Systemseitig verbundene Bluetooth-Geräte bei der letzten Suche (zur Fehlersuche im Banner)
    private(set) var connectedDevices: [String] = []

    var isReady: Bool { state == .ready }

    func entry(for id: UInt16) -> CatalogEntry? { catalogByID[id] }

    func entry(named name: String) -> CatalogEntry? { catalog.first { $0.name == name } }

    // MARK: Intern

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [OBDLink.Characteristic: CBCharacteristic] = [:]
    @ObservationIgnored private var catalogByID: [UInt16: CatalogEntry] = [:]
    @ObservationIgnored private var liveIDs: [UInt16] = []
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReads: [OBDLink.Characteristic: [CheckedContinuation<Data, Error>]] = [:]
    @ObservationIgnored private var pendingWrites: [OBDLink.Characteristic: [CheckedContinuation<Void, Error>]] = [:]
    @ObservationIgnored private var discoveryContinuation: CheckedContinuation<Void, Error>?
    /// Weitere verbundene Geräte, die noch zu prüfen sind, und solche ohne OBD-Link-Service
    @ObservationIgnored private var candidates: [CBPeripheral] = []
    @ObservationIgnored private var rejected: Set<UUID> = []
    @ObservationIgnored private var systemPollTask: Task<Void, Never>?
    /// Vom Polling übernommenes Gerät, dessen connect noch läuft (nicht erneut abbrechen und neu starten)
    @ObservationIgnored private var adoptedFromSystem: UUID?

    private static let savedPeripheralKey = "savedPeripheral"
    private static let catalogCacheKey = "catalogCache"
    private static let esp32Name = "OBD-Display"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: - Verbinden

    private func findAndConnect() {
        guard let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }

        // 1. Schon systemseitig verbunden (Zeit-Synchronisation über die HID-Verbindung)?
        let untried = systemConnectedCandidates()
        if let first = untried.first {
            candidates = Array(untried.dropFirst())
            connect(first)
            return
        }
        // 2. Gemerktes Gerät: connect ohne Zeitlimit, iOS verbindet, sobald es in Reichweite ist.
        if let saved = UserDefaults.standard.string(forKey: Self.savedPeripheralKey).flatMap(UUID.init),
           !rejected.contains(saved),
           let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            connect(known)
        }
        // 3. Zusätzlich suchen (findet das Gerät auch, wenn es noch nie verbunden war)
        state = peripheral == nil ? .searching : .connecting
        central.scanForPeripherals(withServices: [OBDLink.service])
        startSystemConnectionPolling()
    }

    /// Systemseitig verbundene Geräte, die noch nicht abgelehnt wurden. iOS liefert das Gerät über den
    /// OBD-Link-Service nur, wenn es dessen Gerätestruktur kennt, und der Name kann noch ein alter sein
    /// (gecacht). Deshalb zusätzlich alle verbundenen HID-/Geräteinfo-Geräte, "OBD-Display" zuerst; Geräte ohne
    /// OBD-Link-Service werden in setUp übersprungen.
    private func systemConnectedCandidates() -> [CBPeripheral] {
        guard let central else { return [] }
        let byService = central.retrieveConnectedPeripherals(withServices: [OBDLink.service])
        let byProfile = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812"),
                                                                             CBUUID(string: "180A")])
            .sorted { ($0.name == Self.esp32Name ? 0 : 1) < ($1.name == Self.esp32Name ? 0 : 1) }
        var seen = Set<UUID>()
        let found = (byService + byProfile).filter { seen.insert($0.identifier).inserted }
        connectedDevices = found.map { $0.name ?? "ohne Namen" }
        return found.filter { !rejected.contains($0.identifier) }
    }

    /// Startet die App vor der Systemverbindung, verbindet iOS den gekoppelten ESP32 kurz darauf selbst (HID).
    /// Danach sendet er kein Advertising mehr, der Scan findet ihn also nie. Deshalb solange nicht verbunden alle
    /// 2 s nachsehen, ob iOS inzwischen ein passendes Gerät verbunden hat, und dieses übernehmen.
    private func startSystemConnectionPolling() {
        guard systemPollTask == nil else { return }
        systemPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkSystemConnections()
            }
        }
    }

    private func stopSystemConnectionPolling() {
        systemPollTask?.cancel()
        systemPollTask = nil
    }

    private func checkSystemConnections() {
        guard let central, central.state == .poweredOn, peripheral?.state != .connected,
              let first = systemConnectedCandidates().first,
              first.identifier != adoptedFromSystem else { return }   // läuft schon
        // Ausstehenden connect bzw. Scan aufgeben; peripheral vorher leeren, damit die Abbruchmeldung des
        // alten connect in handleDisconnected ignoriert wird.
        if let pending = peripheral {
            peripheral = nil
            central.cancelPeripheralConnection(pending)
        }
        central.stopScan()
        candidates = []
        adoptedFromSystem = first.identifier
        connect(first)
    }

    private func connect(_ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        state = .connecting
        central?.connect(target)
    }

    private func handleConnected(_ id: UUID) {
        guard let peripheral, peripheral.identifier == id else { return }
        central?.stopScan()
        stopSystemConnectionPolling()
        adoptedFromSystem = nil
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
        state = .loading
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            await self?.setUp()
        }
    }

    private func handleDisconnected(_ id: UUID, error: String?) {
        // Meldung für ein übersprungenes Gerät (ohne OBD-Link-Service) - nicht für das aktuelle
        guard id == peripheral?.identifier else { return }
        adoptedFromSystem = nil
        setupTask?.cancel()
        characteristics = [:]
        failPending(with: OBDLinkError.disconnected)
        scanRunning = false
        if let error {
            lastError = error
        }
        guard let central, central.state == .poweredOn, let peripheral else {
            findAndConnect()
            return
        }
        // Sofort wieder verbinden (A-CON-04); ein ausstehender connect hat kein Zeitlimit.
        state = .connecting
        central.connect(peripheral)
        startSystemConnectionPolling()
    }

    /// Nach dem Verbinden: Services, Geräteinfo, Katalog, Notifications, Einstellungen, Live-Abo.
    private func setUp() async {
        guard let peripheral else { return }
        do {
            try await discover(peripheral)
            let info = try await read(.deviceInfo)
            guard let device = DeviceInfo(info) else { throw OBDLinkError.badData("Geräteinfo") }
            deviceInfo = device
            guard device.protocolVersion == OBDLink.protocolVersion else {
                state = .incompatible("Firmware nutzt Protokoll \(device.protocolVersion), die App \(OBDLink.protocolVersion). Bitte App oder Firmware aktualisieren.")
                return
            }
            try await loadCatalog(crc: device.catalogCRC, count: Int(device.valueCount))
            for characteristic in OBDLink.Characteristic.allCases where characteristic.notifies {
                if let c = characteristics[characteristic] {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            try await reloadSettings()
            freeDIDs = FreeDID.list(from: try await read(.freeDIDs))
            state = .ready
            try await sendLiveSubscription()
        } catch OBDLinkError.serviceMissing {
            if Task.isCancelled { return }
            skipCurrentPeripheral()
        } catch {
            // Abgebrochen (Verbindung getrennt): handleDisconnected verbindet bereits neu
            if Task.isCancelled { return }
            lastError = error.localizedDescription
            // Meist Kopplung abgelehnt oder Verbindung weg: trennen, der Rest läuft über handleDisconnected
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    /// Das verbundene Gerät hat keinen OBD-Link-Service: überspringen und das nächste prüfen.
    private func skipCurrentPeripheral() {
        guard let skipped = peripheral else { return }
        rejected.insert(skipped.identifier)
        peripheral = nil
        central?.cancelPeripheralConnection(skipped)   // trennt nur die App, nicht die Verbindung des Systems
        if !candidates.isEmpty {
            connect(candidates.removeFirst())
            return
        }
        if skipped.name == Self.esp32Name {
            lastError = "„OBD-Display“ ist verbunden, meldet aber keinen OBD-Link-Service. Entweder läuft noch "
                + "eine ältere Firmware, oder iOS kennt die Gerätestruktur noch von früher: dann unter "
                + "Einstellungen → Bluetooth „OBD-Display“ ignorieren, neu koppeln und die App neu starten."
        }
        findAndConnect()
    }

    private func discover(_ peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            discoveryContinuation = continuation
            peripheral.discoverServices([OBDLink.service])
        }
    }

    private func loadCatalog(crc: UInt32, count: Int) async throws {
        if let data = UserDefaults.standard.data(forKey: Self.catalogCacheKey),
           let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data), cached.crc == crc {
            setCatalog(cached.entries)
            return
        }
        var entries: [CatalogEntry] = []
        while entries.count < count {
            var command = Data([OBDLink.Command.catalogPage.rawValue])
            command.appendU16(UInt16(entries.count))
            try await write(.command, command)
            guard let page = CatalogPage(try await read(.catalog)), !page.entries.isEmpty else {
                throw OBDLinkError.badData("Werte-Katalog")
            }
            entries += page.entries
        }
        setCatalog(entries)
        if let data = try? JSONEncoder().encode(CachedCatalog(crc: crc, entries: entries)) {
            UserDefaults.standard.set(data, forKey: Self.catalogCacheKey)
        }
    }

    private func setCatalog(_ entries: [CatalogEntry]) {
        catalog = entries
        catalogByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Lesen und Schreiben (async über die Delegate-Rückmeldungen)

    private func read(_ characteristic: OBDLink.Characteristic) async throws -> Data {
        guard let peripheral, let c = characteristics[characteristic] else { throw OBDLinkError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[characteristic, default: []].append(continuation)
            peripheral.readValue(for: c)
        }
    }

    private func write(_ characteristic: OBDLink.Characteristic, _ data: Data) async throws {
        guard let peripheral, let c = characteristics[characteristic] else { throw OBDLinkError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingWrites[characteristic, default: []].append(continuation)
            peripheral.writeValue(data, for: c, type: .withResponse)
        }
    }

    private func failPending(with error: Error) {
        for list in pendingReads.values { list.forEach { $0.resume(throwing: error) } }
        for list in pendingWrites.values { list.forEach { $0.resume(throwing: error) } }
        pendingReads = [:]
        pendingWrites = [:]
        discoveryContinuation?.resume(throwing: error)
        discoveryContinuation = nil
    }

    // MARK: - Öffentliche Aktionen

    /// Werte, die die aktuelle Ansicht live braucht (≥ 1 Hz, Z-03). Leer = keine.
    func setLiveValues(_ ids: [UInt16]) {
        var seen = Set<UInt16>()
        let unique = Array(ids.filter { seen.insert($0).inserted }.prefix(64))
        guard unique != liveIDs else { return }
        liveIDs = unique
        Task { try? await sendLiveSubscription() }
    }

    private func sendLiveSubscription() async throws {
        guard isReady else { return }
        var command = Data([OBDLink.Command.liveSubscribe.rawValue])
        liveIDs.forEach { command.appendU16($0) }
        try await write(.command, command)
    }

    /// Einmal den aktuellen Stand aller Werte (oder einer Gruppe) anfordern.
    func requestSnapshot(group: ValueGroup? = nil) {
        guard isReady else { return }
        var command = Data([OBDLink.Command.snapshot.rawValue])
        if let group { command.append(group.rawValue) }
        perform(command)
    }

    func send(_ command: OBDLink.Command) {
        perform(Data([command.rawValue]))
    }

    func startRangeScan(headers: ClosedRange<UInt16>, dids: ClosedRange<UInt16>) {
        var command = Data([OBDLink.Command.scanRange.rawValue])
        command.appendU16(headers.lowerBound)
        command.appendU16(headers.upperBound)
        command.appendU16(dids.lowerBound)
        command.appendU16(dids.upperBound)
        startScan(command)
    }

    func startScan(_ kind: OBDLink.Command) {
        startScan(Data([kind.rawValue]))
    }

    private func startScan(_ command: Data) {
        scanSummary = nil
        scanProgress = nil
        Task {
            do {
                try await write(.command, command)
                scanRunning = true
            } catch {
                lastError = "Scan nicht gestartet: \(error.localizedDescription)"
            }
        }
    }

    private func perform(_ command: Data) {
        Task {
            do {
                try await write(.command, command)
            } catch {
                lastError = "Befehl abgelehnt: \(error.localizedDescription)"
            }
        }
    }

    func reloadSettings() async throws {
        settings = SettingDefinition.parseTLV(try await read(.settings))
    }

    /// Schreibt Einstellungen (Schlüssel → Wert). Die Ergebnisse kommen als Notification.
    func writeSettings(_ changes: [UInt8: Data]) async {
        var data = Data()
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            data.append(SettingDefinition.tlv(key: key, value: value))
            settingFeedback[key] = "wird gesendet …"
        }
        do {
            try await write(.settings, data)
            try await reloadSettings()
        } catch {
            lastError = "Einstellungen nicht gesendet: \(error.localizedDescription)"
        }
    }

    func saveFreeDIDs(_ list: [FreeDID]) async -> Bool {
        do {
            try await write(.freeDIDs, FreeDID.encode(list))
            freeDIDs = list
            return true
        } catch {
            lastError = "DID-Liste abgelehnt: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Eingehende Daten

    private func handleValue(_ characteristic: OBDLink.Characteristic, data: Data?, error: String?) {
        // Antwort auf ein readValue?
        if var waiting = pendingReads[characteristic], !waiting.isEmpty {
            let continuation = waiting.removeFirst()
            pendingReads[characteristic] = waiting
            if let error {
                continuation.resume(throwing: OBDLinkError.att(error))
            } else {
                continuation.resume(returning: data ?? Data())
            }
            return
        }
        guard let data, error == nil else { return }

        switch characteristic {
        case .live:
            guard let packet = LivePacket(data) else { return }
            let now = Date.now
            for record in packet.records {
                values[record.id] = ValueSample(value: record.value, status: record.status, updated: now)
            }
        case .status:
            if let parsed = DeviceStatus(data) {
                status = parsed
                if !parsed.scanRunning, scanRunning, scanProgress == nil { scanRunning = false }
            }
        case .settingResult:
            var r = ByteReader(data)
            if let key = r.u8(), let code = r.u8() {
                settingFeedback[key] = OBDLink.settingResultText(code)
                if code == 6 { Task { try? await reloadSettings() } }
            }
        case .scanResult:
            guard let event = ScanEvent(data) else { return }
            switch event {
            case .progress(let header, let did, let percent):
                scanRunning = true
                scanProgress = (header, did, percent)
            case .hit(let hit):
                scanStore.add(hit)
            case .finished(let hits, let reason):
                scanRunning = false
                scanProgress = nil
                scanSummary = switch reason {
                case 0: "Fertig: \(hits) Treffer"
                case 1: "Abgebrochen nach \(hits) Treffern"
                default: "Verbindung zum Fahrzeug verloren (\(hits) Treffer)"
                }
            }
        case .rawData:
            if let sample = RawSample(data) {
                rawSamples[sample.key] = sample
            }
        default:
            break
        }
    }

    private func handleWrite(_ characteristic: OBDLink.Characteristic, error: String?) {
        guard var waiting = pendingWrites[characteristic], !waiting.isEmpty else { return }
        let continuation = waiting.removeFirst()
        pendingWrites[characteristic] = waiting
        if let error {
            continuation.resume(throwing: OBDLinkError.att(error))
        } else {
            continuation.resume()
        }
    }

    private func handleServices(error: String?) {
        guard let peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == OBDLink.service }) else {
            discoveryContinuation?.resume(throwing: error.map(OBDLinkError.att) ?? OBDLinkError.serviceMissing)
            discoveryContinuation = nil
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    private func handleCharacteristics(error: String?) {
        guard let peripheral,
              let service = peripheral.services?.first(where: { $0.uuid == OBDLink.service }) else { return }
        if let error {
            discoveryContinuation?.resume(throwing: OBDLinkError.att(error))
        } else {
            var found: [OBDLink.Characteristic: CBCharacteristic] = [:]
            for c in service.characteristics ?? [] {
                if let kind = OBDLink.Characteristic(uuid: c.uuid) { found[kind] = c }
            }
            characteristics = found
            discoveryContinuation?.resume()
        }
        discoveryContinuation = nil
    }

    private func handleStateUpdate(_ newState: CBManagerState) {
        switch newState {
        case .poweredOn:
            rejected = []
            findAndConnect()
        case .unauthorized:
            state = .unauthorized
        default:
            state = .bluetoothOff
            stopSystemConnectionPolling()
            failPending(with: OBDLinkError.disconnected)
        }
    }

    private func handleDiscovery(_ id: UUID) {
        guard let central, peripheral?.state != .connected,
              let found = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        central.stopScan()
        connect(found)
    }
}

private struct CachedCatalog: Codable {
    var crc: UInt32
    var entries: [CatalogEntry]
}

enum OBDLinkError: LocalizedError {
    case notConnected
    case disconnected
    case badData(String)
    case att(String)
    case serviceMissing

    var errorDescription: String? {
        switch self {
        case .notConnected: "Nicht verbunden"
        case .disconnected: "Verbindung getrennt"
        case .badData(let what): "Ungültige Daten: \(what)"
        case .att(let message): message
        case .serviceMissing: "OBD-Link-Service fehlt"
        }
    }
}

// MARK: - CoreBluetooth-Delegates (Main-Queue)

extension OBDLinkManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { handleStateUpdate(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { handleDiscovery(id) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { handleConnected(id) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let id = peripheral.identifier
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleDisconnected(id, error: message) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let id = peripheral.identifier
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleDisconnected(id, error: message) }
    }
}

extension OBDLinkManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleServices(error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleCharacteristics(error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let kind = OBDLink.Characteristic(uuid: characteristic.uuid) else { return }
        let data = characteristic.value
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleValue(kind, data: data, error: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let kind = OBDLink.Characteristic(uuid: characteristic.uuid) else { return }
        let message = error?.localizedDescription
        MainActor.assumeIsolated { handleWrite(kind, error: message) }
    }
}
