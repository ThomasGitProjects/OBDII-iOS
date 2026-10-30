import SwiftUI
import UIKit

/// Konfiguration des ESP32 (A-SET-01…05, Z-08), Gerätestatus und Befehle.
struct SettingsView: View {
    @Environment(OBDLinkManager.self) private var manager
    @State private var edits: [UInt8: String] = [:]
    @State private var inputErrors: [UInt8: String] = [:]
    @State private var confirmConnection = false
    @State private var confirmAction: DeviceAction?
    @State private var saving = false

    enum DeviceAction: String, Identifiable {
        case resetTrip = "Trip zurücksetzen"
        case resetStart = "„Ab Start“ zurücksetzen"
        case restart = "ESP32 neu starten"
        case deleteBonds = "Alle Kopplungen löschen"
        case factoryReset = "Werkseinstellungen"

        var id: String { rawValue }

        var command: OBDLink.Command {
            switch self {
            case .resetTrip: .resetTrip
            case .resetStart: .resetStart
            case .restart: .restart
            case .deleteBonds: .deleteBonds
            case .factoryReset: .factoryReset
            }
        }

        var warning: String {
            switch self {
            case .resetTrip: "Trip-Strecke, -Energie und -Verbrauch beginnen bei 0."
            case .resetStart: "Alle „Ab Start“-Werte beginnen bei 0."
            case .restart: "Die Verbindung wird kurz unterbrochen."
            case .deleteBonds: "Danach muss das iPhone neu gekoppelt werden: „OBD-Display“ unter Einstellungen → Bluetooth ignorieren und neu verbinden."
            case .factoryReset: "Alle Einstellungen, frei gewählten DIDs, Trip und „Ab Start“ werden gelöscht, der ESP32 startet neu."
            }
        }
    }

    private static let connectionKeys: [UInt8] = [0x01, 0x02, 0x04, 0x05]
    private static let vehicleKeys: [UInt8] = [0x10, 0x11, 0x12, 0x13, 0x14, 0x15]
    private static let warningKeys: [UInt8] = [0x20, 0x21, 0x22]

    var body: some View {
        NavigationStack {
            Form {
                if !manager.isReady {
                    ConnectionBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if manager.status.connectionPending {
                    Section {
                        Text("Neue Verbindungseinstellungen sind vorgemerkt.")
                        Button("Übernehmen …") { confirmConnection = true }
                        Button("Verwerfen", role: .destructive) { manager.send(.discardConnection) }
                    }
                }
                settingsSection("Verbindung zum OBD-Dongle", keys: Self.connectionKeys,
                                footer: "Wird erst nach Bestätigung übernommen. Kommt die neue Verbindung nicht binnen 60 s zustande, stellt der ESP32 die vorherige wieder her.")
                settingsSection("Abfrage und Anzeige", keys: Self.vehicleKeys, footer: nil)
                settingsSection("Warnschwellen", keys: Self.warningKeys, footer: "Werte jenseits der Schwelle werden in der App orange hervorgehoben.")
                Section {
                    Button(saving ? "Sende …" : "Änderungen senden", action: save)
                        .disabled(!manager.isReady || edits.isEmpty || saving)
                }
                statusSection
                Section("Aktionen") {
                    ForEach([DeviceAction.resetTrip, .resetStart, .restart, .deleteBonds, .factoryReset]) { action in
                        Button(action.rawValue, role: action == .factoryReset || action == .deleteBonds ? .destructive : nil) {
                            confirmAction = action
                        }
                        .disabled(!manager.isReady)
                    }
                }
                deviceSection
            }
            .navigationTitle("Einstellungen")
            .refreshable { try? await manager.reloadSettings() }
            .confirmationDialog("Neue Verbindung übernehmen?", isPresented: $confirmConnection, titleVisibility: .visible) {
                Button("Übernehmen") { manager.send(.confirmConnection) }
            } message: {
                Text("Der ESP32 trennt sich vom Dongle und verbindet sich mit den neuen Einstellungen.")
            }
            .confirmationDialog(confirmAction?.rawValue ?? "", isPresented: actionBinding, titleVisibility: .visible,
                                presenting: confirmAction) { action in
                Button(action.rawValue, role: .destructive) { manager.send(action.command) }
            } message: { action in
                Text(action.warning)
            }
        }
    }

    private var actionBinding: Binding<Bool> {
        Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } })
    }

    @ViewBuilder
    private func settingsSection(_ title: String, keys: [UInt8], footer: String?) -> some View {
        Section {
            ForEach(keys.compactMap(SettingDefinition.definition(for:))) { definition in
                settingRow(definition)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func settingRow(_ definition: SettingDefinition) -> some View {
        let current = manager.settings[definition.key].map(definition.text(from:)) ?? ""
        let binding = Binding<String>(
            get: { edits[definition.key] ?? current },
            set: { newValue in
                if newValue == current { edits[definition.key] = nil } else { edits[definition.key] = newValue }
                inputErrors[definition.key] = nil
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent(definition.title) {
                if definition.isReadOnly {
                    Text(current == "1" ? "ja" : "nein")
                } else if definition.isWriteOnly {
                    SecureField("unverändert", text: binding)
                        .multilineTextAlignment(.trailing)
                } else {
                    TextField(definition.unit, text: binding)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(keyboard(for: definition))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            if !definition.unit.isEmpty || !definition.help.isEmpty {
                Text([definition.unit, definition.help].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = inputErrors[definition.key] {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let feedback = manager.settingFeedback[definition.key] {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func keyboard(for definition: SettingDefinition) -> UIKeyboardType {
        switch definition.kind {
        case .text: .default
        case .ipv4: .decimalPad
        case .integer(_, let signed): signed ? .numbersAndPunctuation : .numberPad
        }
    }

    private func save() {
        var changes: [UInt8: Data] = [:]
        var errors: [UInt8: String] = [:]
        for (key, text) in edits {
            guard let definition = SettingDefinition.definition(for: key) else { continue }
            switch definition.encode(text) {
            case .success(let data): changes[key] = data
            case .failure(let error): errors[key] = error.message
            }
        }
        inputErrors = errors
        guard errors.isEmpty, !changes.isEmpty else { return }
        saving = true
        Task {
            await manager.writeSettings(changes)
            edits = [:]
            saving = false
        }
    }

    private var statusSection: some View {
        let status = manager.status
        return Section("Status des OBD-Displays") {
            statusRow("WLAN zum Dongle", status.wifiConnected)
            statusRow("Dongle verbunden", status.dongleConnected)
            statusRow("Fahrzeug liefert Werte", status.vehicleLive)
            statusRow("Zeit vom iPhone", status.timeSynced)
            if let sync = status.lastSync {
                LabeledContent("Letzte Synchronisation", value: sync.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Abfragerunden", value: "\(status.roundsPerSecond.formatted(.number.precision(.fractionLength(1)))) /s")
            LabeledContent("Freier Speicher", value: "\(status.freeHeapKB) KB")
            LabeledContent("Status", value: status.text)
        }
    }

    private func statusRow(_ title: String, _ on: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
        }
    }

    private var deviceSection: some View {
        Section("Gerät") {
            if let info = manager.deviceInfo {
                LabeledContent("Firmware", value: info.firmwareVersion)
                LabeledContent("Protokoll", value: "\(info.protocolVersion)")
                LabeledContent("Geräte-ID", value: info.deviceID)
                LabeledContent("Werte im Katalog", value: "\(info.valueCount)")
            } else {
                Text("Nicht verbunden").foregroundStyle(.secondary)
            }
        }
    }
}
