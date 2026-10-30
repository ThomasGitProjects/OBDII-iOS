import SwiftUI

/// Tabs der App. Welche Werte der ESP32 live sendet, hängt vom sichtbaren Tab ab (Z-03, Z-04): nur die Live-
/// und die „Ab Start“-Ansicht abonnieren Werte, die übrigen holen sich bei Bedarf einen Snapshot.
enum AppTab: Hashable {
    case live, sinceStart, values, scan, settings
}

struct ContentView: View {
    @Environment(OBDLinkManager.self) private var manager
    @Environment(AppPreferences.self) private var preferences
    @State private var tab: AppTab = .live

    var body: some View {
        TabView(selection: $tab) {
            Tab("Live", systemImage: "gauge.with.dots.needle.67percent", value: .live) {
                LiveView()
            }
            Tab("Ab Start", systemImage: "flag.checkered", value: .sinceStart) {
                SinceStartView()
            }
            Tab("Werte", systemImage: "list.bullet.rectangle", value: .values) {
                ValuesView()
            }
            Tab("Scan", systemImage: "magnifyingglass", value: .scan) {
                ScanView()
            }
            Tab("Einstellungen", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
        .onChange(of: tab, initial: true) { updateLiveValues() }
        .onChange(of: manager.isReady) { updateLiveValues() }
        .onChange(of: manager.catalog.count) { updateLiveValues() }
        .onChange(of: preferences.liveValueNames) { updateLiveValues() }
        .alert("Hinweis", isPresented: errorBinding) {
            Button("OK") { manager.lastError = nil }
        } message: {
            Text(manager.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { manager.lastError != nil }, set: { if !$0 { manager.lastError = nil } })
    }

    private func updateLiveValues() {
        switch tab {
        case .live:
            manager.setLiveValues(preferences.liveValueNames.compactMap { manager.entry(named: $0)?.id })
        case .sinceStart:
            manager.setLiveValues(manager.catalog.filter { $0.group == .sinceStart }.map(\.id))
        default:
            manager.setLiveValues([])
        }
    }
}

/// Verbindungsstatus oben in jeder Ansicht, solange keine Verbindung besteht.
struct ConnectionBanner: View {
    @Environment(OBDLinkManager.self) private var manager

    var body: some View {
        if !manager.isReady {
            HStack(spacing: 10) {
                if case .incompatible = manager.state {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView()
                }
                Text(manager.state.text)
                    .font(.subheadline)
                Spacer()
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}

/// Darstellung eines Werts mit Nachkommastellen und Einheit aus dem Katalog.
enum ValueText {
    static func format(_ sample: OBDLinkManager.ValueSample?, _ entry: CatalogEntry?) -> String {
        guard let sample, sample.status != .none, sample.value.isFinite else { return "--" }
        let number = Double(sample.value).formatted(.number.precision(.fractionLength(entry?.decimals ?? 1)))
        guard let unit = entry?.unit, !unit.isEmpty else { return number }
        return "\(number) \(unit)"
    }

    static func number(_ sample: OBDLinkManager.ValueSample?, _ entry: CatalogEntry?) -> String {
        guard let sample, sample.status != .none, sample.value.isFinite else { return "--" }
        return Double(sample.value).formatted(.number.precision(.fractionLength(entry?.decimals ?? 1)))
    }
}

extension OBDLinkManager {
    /// Ganzzahlige Einstellung (für die Warnschwellen), nil wenn unbekannt.
    func intSetting(_ key: UInt8) -> Int? {
        guard let definition = SettingDefinition.definition(for: key), let data = settings[key] else { return nil }
        return Int(definition.text(from: data))
    }

    /// true, wenn der Wert über bzw. unter seiner Warnschwelle liegt (A-VAL-05).
    func isWarning(_ entry: CatalogEntry) -> Bool {
        guard let sample = values[entry.id], sample.status == .valid else { return false }
        let v = Double(sample.value)
        switch entry.name {
        case "Temperatur": return intSetting(0x20).map { v > Double($0) } ?? false
        case "Zelldrift": return intSetting(0x21).map { v > Double($0) } ?? false
        case "SoC": return intSetting(0x22).map { v < Double($0) } ?? false
        default: return false
        }
    }
}
