import SwiftUI

/// DID-Scan (Z-05) und frei gewählte DIDs (Z-06).
struct ScanView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case scan = "Scan"
        case myDIDs = "Meine DIDs"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .scan

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBanner()
                Picker("Bereich", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                switch pane {
                case .scan: ScanPanel()
                case .myDIDs: FreeDIDsPanel()
                }
            }
            .navigationTitle("Scan")
        }
    }
}

// MARK: - Scan

private struct ScanPanel: View {
    enum Mode: String, CaseIterable, Identifiable {
        case range = "DID-Bereich"
        case sweep = "Vergleichssuche"
        case ecu = "Steuergeräte"
        var id: String { rawValue }
    }

    @Environment(OBDLinkManager.self) private var manager
    @State private var mode: Mode = .range
    @State private var headerFrom = "781"
    @State private var headerTo = "781"
    @State private var didFrom = "0000"
    @State private var didTo = "00FF"
    @State private var selectedHit: ScanHit?
    @State private var confirmClear = false
    @State private var csvURL: URL?

    var body: some View {
        List {
            Section {
                Picker("Art", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                switch mode {
                case .range:
                    hexRow("Steuergerät von", $headerFrom, "bis", $headerTo)
                    hexRow("DID von", $didFrom, "bis", $didTo)
                case .sweep:
                    Text("Wie die DID-Suche per Taste: erster Durchlauf über alle bekannten Steuergeräte, danach nur noch Änderungen.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .ecu:
                    Text("Sucht alle Steuergeräte 700–7F7 und probiert einige bekannte DIDs.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if manager.scanRunning {
                    if let progress = manager.scanProgress {
                        ProgressView(value: Double(progress.percent), total: 100) {
                            Text(String(format: "%03X:%04X", progress.header, progress.did))
                                .monospacedDigit()
                        }
                    } else {
                        ProgressView("Scan läuft …")
                    }
                    Button("Abbrechen", role: .destructive) { manager.send(.scanAbort) }
                } else {
                    Button("Scan starten", systemImage: "play.fill", action: start)
                        .disabled(!manager.isReady || !inputValid)
                }
                if let summary = manager.scanSummary {
                    Text(summary).font(.footnote)
                }
            } footer: {
                Text("Während des Scans pausiert die normale Abfrage. Treffer bleiben in der App gespeichert.")
            }

            Section("\(manager.scanStore.hits.count) Treffer") {
                ForEach(manager.scanStore.sortedHits) { hit in
                    Button { selectedHit = hit } label: { HitRow(hit: hit) }
                        .disabled(hit.isECU || hit.isNegative)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let csvURL {
                    ShareLink(item: csvURL) { Label("Export", systemImage: "square.and.arrow.up") }
                }
                Button("Leeren", systemImage: "trash") { confirmClear = true }
                    .disabled(manager.scanStore.hits.isEmpty)
            }
        }
        .onChange(of: manager.scanStore.hits.count, initial: true) {
            csvURL = manager.scanStore.hits.isEmpty ? nil : manager.scanStore.exportCSV()
        }
        .confirmationDialog("Alle Treffer löschen?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { manager.scanStore.removeAll() }
        }
        .sheet(item: $selectedHit) { hit in
            AddFreeDIDView(key: DIDKey(header: hit.header, did: hit.did), sample: hit.bytes)
        }
    }

    private func hexRow(_ l1: String, _ v1: Binding<String>, _ l2: String, _ v2: Binding<String>) -> some View {
        HStack {
            Text(l1)
            TextField("", text: v1).frame(width: 60)
            Text(l2)
            TextField("", text: v2).frame(width: 60)
        }
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .monospaced()
    }

    private var inputValid: Bool {
        mode != .range || parsedRange != nil
    }

    private var parsedRange: (ClosedRange<UInt16>, ClosedRange<UInt16>)? {
        guard let h1 = UInt16(headerFrom, radix: 16), let h2 = UInt16(headerTo, radix: 16),
              let d1 = UInt16(didFrom, radix: 16), let d2 = UInt16(didTo, radix: 16),
              h1 >= 0x700, h2 <= 0x7F7, h1 <= h2, d1 <= d2
        else { return nil }
        return (h1...h2, d1...d2)
    }

    private func start() {
        switch mode {
        case .range:
            if let range = parsedRange { manager.startRangeScan(headers: range.0, dids: range.1) }
        case .sweep:
            manager.startScan(.scanSweep)
        case .ecu:
            manager.startScan(.scanECU)
        }
    }
}

private struct HitRow: View {
    let hit: ScanHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hit.isECU {
                Text(String(format: "Steuergerät %03X", hit.header)).font(.headline)
            } else {
                Text(hit.id).font(.headline.monospaced())
                if hit.isNegative {
                    Text(String(format: "abgelehnt, NRC %02X", hit.nrc)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(hit.bytes.hexString).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - Frei gewählte DIDs

private struct FreeDIDsPanel: View {
    @Environment(OBDLinkManager.self) private var manager
    @Environment(AppPreferences.self) private var preferences
    @State private var editing: FreeDID?
    @State private var adding = false

    var body: some View {
        List {
            if manager.freeDIDs.isEmpty {
                Text("Noch keine DIDs. Im Scan einen Treffer antippen oder oben „+“ wählen.")
                    .foregroundStyle(.secondary)
            }
            ForEach(manager.freeDIDs) { entry in
                Button { editing = entry } label: { row(entry) }
            }
            .onDelete { offsets in
                var list = manager.freeDIDs
                list.remove(atOffsets: offsets)
                Task { _ = await manager.saveFreeDIDs(list) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Hinzufügen", systemImage: "plus") { adding = true }
                    .disabled(!manager.isReady || manager.freeDIDs.count >= 32)
            }
        }
        .sheet(item: $editing) { entry in
            AddFreeDIDView(key: entry.key, sample: manager.rawSamples[entry.key]?.bytes ?? [])
        }
        .sheet(isPresented: $adding) {
            AddFreeDIDView(key: nil, sample: [])
        }
    }

    private func row(_ entry: FreeDID) -> some View {
        let conversion = preferences.conversion(for: entry.key)
        let sample = manager.rawSamples[entry.key]
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(conversion?.name.isEmpty == false ? conversion!.name : entry.key.text).font(.headline)
                Spacer()
                if let sample, sample.status == 0, let text = conversion?.formatted(sample.bytes) {
                    Text(text).monospacedDigit()
                }
            }
            HStack {
                Text(entry.key.text).monospaced()
                Text("alle \(Double(entry.intervalMS) / 1000, specifier: "%.2g") s")
                Spacer()
                Text(rawText(sample)).monospaced()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }

    private func rawText(_ sample: RawSample?) -> String {
        guard let sample else { return "–" }
        switch sample.status {
        case 0: return sample.bytes.hexString
        case 1: return "abgelehnt"
        default: return "keine Antwort"
        }
    }
}

/// Neue DID zur dauerhaften Abfrage hinzufügen bzw. Umrechnung und Intervall ändern.
struct AddFreeDIDView: View {
    @Environment(OBDLinkManager.self) private var manager
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    let key: DIDKey?
    let sample: [UInt8]

    @State private var headerText = ""
    @State private var didText = ""
    @State private var interval = 1000.0
    @State private var conversion = DIDConversion()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("DID") {
                    if let key {
                        LabeledContent("Steuergerät:DID", value: key.text)
                    } else {
                        TextField("Steuergerät (hex, z. B. 781)", text: $headerText)
                        TextField("DID (hex, z. B. 0008)", text: $didText)
                    }
                    if !currentBytes.isEmpty {
                        LabeledContent("Rohbytes", value: currentBytes.hexString)
                    }
                    Stepper("Abfrage alle \(interval / 1000, specifier: "%.2g") s", value: $interval,
                            in: 250...60000, step: 250)
                }
                Section {
                    TextField("Name", text: $conversion.name)
                    Stepper("Ab Byte \(conversion.startByte)", value: $conversion.startByte, in: 0...47)
                    Stepper("Länge \(conversion.length) Byte", value: $conversion.length, in: 1...4)
                    Toggle("Little-Endian (BYD)", isOn: $conversion.littleEndian)
                    Toggle("Mit Vorzeichen", isOn: $conversion.signed)
                    LabeledContent("Faktor") {
                        TextField("1", value: $conversion.factor, format: .number).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Offset") {
                        TextField("0", value: $conversion.offset, format: .number).multilineTextAlignment(.trailing)
                    }
                    TextField("Einheit", text: $conversion.unit)
                    Stepper("Nachkommastellen \(conversion.decimals)", value: $conversion.decimals, in: 0...4)
                    if let text = conversion.formatted(currentBytes) {
                        LabeledContent("Ergebnis", value: text)
                    }
                } header: {
                    Text("Umrechnung")
                } footer: {
                    Text("Wert = Rohwert × Faktor + Offset. Die Umrechnung gilt nur in der App; bewährte Werte können später fest in die Firmware übernommen werden.")
                }
            }
            .navigationTitle(key == nil ? "DID hinzufügen" : "DID bearbeiten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { Task { await save() } }
                        .disabled(resolvedKey == nil || saving || !manager.isReady)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var resolvedKey: DIDKey? {
        if let key { return key }
        guard let header = UInt16(headerText, radix: 16), let did = UInt16(didText, radix: 16),
              (0x700...0x7F7).contains(header) else { return nil }
        return DIDKey(header: header, did: did)
    }

    private var currentBytes: [UInt8] {
        if let key = resolvedKey, let raw = manager.rawSamples[key], raw.status == 0 { return raw.bytes }
        return sample
    }

    private func load() {
        guard let key else { return }
        if let existing = manager.freeDIDs.first(where: { $0.key == key }) {
            interval = Double(existing.intervalMS)
        }
        conversion = preferences.conversion(for: key) ?? DIDConversion()
    }

    private func save() async {
        guard let key = resolvedKey else { return }
        saving = true
        defer { saving = false }
        var list = manager.freeDIDs.filter { $0.key != key }
        guard list.count < 32 else { return }
        list.append(FreeDID(key: key, intervalMS: UInt16(interval)))
        if await manager.saveFreeDIDs(list) {
            preferences.setConversion(conversion, for: key)
            dismiss()
        }
    }
}
