import SwiftUI

/// Alle Werte nach Gruppen. Unabhängig vom ESP32-Display (Z-04); aktualisiert per Snapshot alle 5 s (Z-03).
struct ValuesView: View {
    @Environment(OBDLinkManager.self) private var manager

    var body: some View {
        NavigationStack {
            List {
                ConnectionBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                ForEach(ValueGroup.allCases) { group in
                    let entries = manager.catalog.filter { $0.group == group }
                    if !entries.isEmpty {
                        Section(group.title) {
                            if group == .module {
                                DisclosureGroup("\(entries.count) Werte") { rows(entries) }
                            } else {
                                rows(entries)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Werte")
            .refreshable { manager.requestSnapshot() }
            .task(id: manager.isReady) {
                // Solange die Ansicht sichtbar ist, alle 5 s den aktuellen Stand holen
                while manager.isReady, !Task.isCancelled {
                    manager.requestSnapshot()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func color(_ sample: OBDLinkManager.ValueSample?, _ entry: CatalogEntry) -> Color {
        guard sample?.status == .valid else { return .secondary }
        return manager.isWarning(entry) ? .orange : .primary
    }

    @ViewBuilder
    private func rows(_ entries: [CatalogEntry]) -> some View {
        ForEach(entries) { entry in
            let sample = manager.values[entry.id]
            HStack {
                Text(entry.name)
                Spacer()
                Text(ValueText.format(sample, entry))
                    .monospacedDigit()
                    .foregroundStyle(color(sample, entry))
            }
        }
    }
}
