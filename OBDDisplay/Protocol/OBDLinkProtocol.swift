import CoreBluetooth
import Foundation

/// BLE-Protokoll „OBD-Link“, Version 1. Spiegel von `docs/ble_protokoll.md` im Firmware-Repository
/// (github.com/ThomasGitProjects/OBDII). Ändert sich dort etwas, wird diese Datei im selben Zug angepasst.
enum OBDLink {
    static let protocolVersion: UInt8 = 1

    /// Basis `1469xxxx-b9d7-4c20-906b-a6a08b2182b9`, `xxxx` = Nummer.
    private static func uuid(_ number: UInt16) -> CBUUID {
        CBUUID(string: String(format: "1469%04X-B9D7-4C20-906B-A6A08B2182B9", number))
    }

    static var service: CBUUID { uuid(0x0001) }

    enum Characteristic: UInt16, CaseIterable, Sendable {
        case deviceInfo = 0x0002
        case status = 0x0003
        case live = 0x0004
        case catalog = 0x0005
        case settings = 0x0006
        case settingResult = 0x0007
        case command = 0x0008
        case scanResult = 0x0009
        case freeDIDs = 0x000A
        case rawData = 0x000B

        var uuid: CBUUID { OBDLink.uuid(rawValue) }

        /// Characteristics, deren Notifications die App abonniert.
        var notifies: Bool {
            switch self {
            case .status, .live, .settingResult, .scanResult, .rawData: true
            default: false
            }
        }

        init?(uuid: CBUUID) {
            guard let match = Self.allCases.first(where: { $0.uuid == uuid }) else { return nil }
            self = match
        }
    }

    /// Befehle an die Characteristic „Befehl“ (3.6).
    enum Command: UInt8, Sendable {
        case restart = 0x01
        case factoryReset = 0x02
        case deleteBonds = 0x03
        case confirmConnection = 0x04
        case discardConnection = 0x05
        case liveSubscribe = 0x10
        case snapshot = 0x11
        case catalogPage = 0x12
        case scanRange = 0x20
        case scanSweep = 0x21
        case scanECU = 0x22
        case scanAbort = 0x23
        case resetTrip = 0x30
        case resetStart = 0x31
    }

    /// Ergebniscodes beim Schreiben von Einstellungen (3.5).
    static func settingResultText(_ code: UInt8) -> String {
        switch code {
        case 0: "übernommen"
        case 1: "unbekannter Schlüssel"
        case 2: "falsche Länge"
        case 3: "außerhalb des Wertebereichs"
        case 4: "nicht erlaubt"
        case 5: "vorgemerkt – Bestätigung nötig"
        case 6: "Verbindung fehlgeschlagen – vorherige Einstellung wiederhergestellt"
        default: "Code \(code)"
        }
    }

    /// Pseudo-DID, mit der der ECU-Scan ein gefundenes Steuergerät meldet (3.7).
    static let ecuFoundDID: UInt16 = 0x3E00
}

// MARK: - Binärdaten lesen und schreiben (little-endian)

struct ByteReader {
    private let buffer: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { buffer = [UInt8](data) }

    var remaining: Int { buffer.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        let o = offset
        offset += 4
        return UInt32(buffer[o]) | UInt32(buffer[o + 1]) << 8 | UInt32(buffer[o + 2]) << 16 | UInt32(buffer[o + 3]) << 24
    }

    mutating func f32() -> Float? {
        u32().map { Float(bitPattern: $0) }
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard remaining >= count else { return nil }
        defer { offset += count }
        return Array(buffer[offset..<offset + count])
    }

    /// Länge (u8), dann UTF-8-Text.
    mutating func string() -> String? {
        guard let length = u8(), let raw = bytes(Int(length)) else { return nil }
        return String(decoding: raw, as: UTF8.self)
    }
}

extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendU32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

extension Array where Element == UInt8 {
    /// z. B. „3C 11 00“
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

// MARK: - Datenformate

/// Geräteinfo (3.1)
struct DeviceInfo: Equatable, Sendable {
    var protocolVersion: UInt8
    var valueCount: UInt16
    var catalogCRC: UInt32
    var deviceID: String
    var capabilities: UInt32
    var firmwareVersion: String

    init?(_ data: Data) {
        var r = ByteReader(data)
        guard let version = r.u8(), r.u8() != nil, let count = r.u16(), let crc = r.u32(),
              let mac = r.bytes(6), let caps = r.u32(), let firmware = r.string()
        else { return nil }
        protocolVersion = version
        valueCount = count
        catalogCRC = crc
        deviceID = mac.map { String(format: "%02X", $0) }.joined(separator: ":")
        capabilities = caps
        firmwareVersion = firmware
    }
}

/// Status (3.2)
struct DeviceStatus: Equatable, Sendable {
    var flags: UInt32 = 0
    var lastSync: Date?
    var utcOffset: Int32 = 0
    var roundsPerSecond: Double = 0
    var freeHeapKB: UInt16 = 0
    var text = ""

    var wifiConnected: Bool { flags & 1 << 0 != 0 }
    var dongleConnected: Bool { flags & 1 << 1 != 0 }
    var vehicleLive: Bool { flags & 1 << 2 != 0 }
    var timeSynced: Bool { flags & 1 << 3 != 0 }
    var timeFromStorageOnly: Bool { flags & 1 << 4 != 0 }
    var scanRunning: Bool { flags & 1 << 5 != 0 }
    var connectionPending: Bool { flags & 1 << 6 != 0 }

    init() {}

    init?(_ data: Data) {
        var r = ByteReader(data)
        guard let flags = r.u32(), let sync = r.u32(), let offset = r.u32(), let rate = r.u16(),
              let heap = r.u16(), let text = r.string()
        else { return nil }
        self.flags = flags
        lastSync = sync == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(sync))
        utcOffset = Int32(bitPattern: offset)
        roundsPerSecond = Double(rate) / 10
        freeHeapKB = heap
        self.text = text
    }
}

/// Status eines Werts (3.3)
enum ValueStatus: UInt8, Sendable {
    case valid = 0
    case stale = 1
    case none = 2
}

/// Ein Datensatz der Live-Daten (3.3)
struct LiveRecord: Sendable {
    var id: UInt16
    var status: ValueStatus
    var value: Float
}

/// Eine Notification der Live-Daten: Art (0 = Live, 1 = Snapshot, 2 = letzter Teil) und Datensätze.
struct LivePacket: Sendable {
    var kind: UInt8
    var sequence: UInt8
    var records: [LiveRecord]

    init?(_ data: Data) {
        var r = ByteReader(data)
        guard let kind = r.u8(), let sequence = r.u8() else { return nil }
        self.kind = kind
        self.sequence = sequence
        var records: [LiveRecord] = []
        while r.remaining >= 8, let id = r.u16(), let status = r.u8(), r.u8() != nil, let value = r.f32() {
            records.append(LiveRecord(id: id, status: ValueStatus(rawValue: status) ?? .none, value: value))
        }
        self.records = records
    }
}

/// Gruppen im Werte-Katalog (3.4)
enum ValueGroup: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case battery = 0, drivetrain, vehicle, calculated, module, sinceStart, trip, statistics

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .battery: "Akku"
        case .drivetrain: "Antrieb"
        case .vehicle: "Fahrzeug"
        case .calculated: "Berechnet"
        case .module: "Akkumodule"
        case .sinceStart: "Ab Start"
        case .trip: "Trip"
        case .statistics: "Statistik"
        }
    }
}

/// Eintrag im Werte-Katalog (3.4)
struct CatalogEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UInt16
    var group: ValueGroup
    var decimals: Int
    var name: String
    var unit: String
}

/// Eine Seite des Werte-Katalogs: Anzahl gesamt, Startindex, Einträge.
struct CatalogPage: Sendable {
    var total: Int
    var start: Int
    var entries: [CatalogEntry]

    init?(_ data: Data) {
        var r = ByteReader(data)
        guard let total = r.u16(), let start = r.u16(), let count = r.u8() else { return nil }
        self.total = Int(total)
        self.start = Int(start)
        var entries: [CatalogEntry] = []
        for _ in 0..<count {
            guard let id = r.u16(), let group = r.u8(), let decimals = r.u8(), let name = r.string(),
                  let unit = r.string()
            else { return nil }
            entries.append(CatalogEntry(id: id, group: ValueGroup(rawValue: group) ?? .calculated,
                                        decimals: Int(decimals), name: name, unit: unit))
        }
        self.entries = entries
    }
}

/// Ereignisse des DID-/ECU-Scans (3.7)
enum ScanEvent: Sendable {
    case progress(header: UInt16, did: UInt16, percent: UInt8)
    case hit(ScanHit)
    case finished(hits: UInt16, reason: UInt8)

    init?(_ data: Data) {
        var r = ByteReader(data)
        switch r.u8() {
        case 0?:
            guard let header = r.u16(), let did = r.u16(), let percent = r.u8() else { return nil }
            self = .progress(header: header, did: did, percent: percent)
        case 1?:
            guard let header = r.u16(), let did = r.u16(), let result = r.u8(), let nrc = r.u8(),
                  let length = r.u8(), let bytes = r.bytes(Int(length))
            else { return nil }
            self = .hit(ScanHit(header: header, did: did, isNegative: result == 1, nrc: nrc, bytes: bytes, date: .now))
        case 2?:
            guard let hits = r.u16(), let reason = r.u8() else { return nil }
            self = .finished(hits: hits, reason: reason)
        default:
            return nil
        }
    }
}

/// Treffer eines Scans
struct ScanHit: Codable, Identifiable, Hashable, Sendable {
    var header: UInt16
    var did: UInt16
    var isNegative: Bool
    var nrc: UInt8
    var bytes: [UInt8]
    var date: Date

    var id: String { DIDKey(header: header, did: did).text }
    var isECU: Bool { did == OBDLink.ecuFoundDID && bytes.isEmpty && !isNegative }
}

/// Rohdaten einer frei gewählten DID (3.8)
struct RawSample: Sendable {
    var key: DIDKey
    var status: UInt8      // 0 = Daten, 1 = negative Antwort, 2 = keine Antwort
    var bytes: [UInt8]
    var date: Date

    init?(_ data: Data) {
        var r = ByteReader(data)
        guard let header = r.u16(), let did = r.u16(), let status = r.u8(), let length = r.u8(),
              let bytes = r.bytes(Int(length))
        else { return nil }
        key = DIDKey(header: header, did: did)
        self.status = status
        self.bytes = bytes
        date = .now
    }
}

/// Steuergerät + DID, z. B. „781:0008“
struct DIDKey: Codable, Hashable, Sendable {
    var header: UInt16
    var did: UInt16

    var text: String { String(format: "%03X:%04X", header, did) }
}

/// Frei gewählte DID (3.8)
struct FreeDID: Codable, Hashable, Identifiable, Sendable {
    var key: DIDKey
    var intervalMS: UInt16

    var id: DIDKey { key }

    static func list(from data: Data) -> [FreeDID] {
        var r = ByteReader(data)
        var list: [FreeDID] = []
        while let header = r.u16(), let did = r.u16(), let interval = r.u16() {
            list.append(FreeDID(key: DIDKey(header: header, did: did), intervalMS: interval))
        }
        return list
    }

    static func encode(_ list: [FreeDID]) -> Data {
        var data = Data()
        for entry in list {
            data.appendU16(entry.key.header)
            data.appendU16(entry.key.did)
            data.appendU16(entry.intervalMS)
        }
        return data
    }
}
