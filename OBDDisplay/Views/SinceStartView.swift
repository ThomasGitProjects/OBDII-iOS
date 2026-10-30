import SwiftUI

/// „Ab Start“ (Z-07): Werte seit dem letzten Start nach längerer Standzeit, wie Seite 2 am Display.
struct SinceStartView: View {
    @Environment(OBDLinkManager.self) private var manager
    @State private var confirmReset = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                ConnectionBanner()
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(manager.catalog.filter { $0.group == .sinceStart }) { entry in
                        ValueTile(name: entry.name, entry: entry)
                    }
                }
                .padding()
                if let minutes = manager.intSetting(0x10) {
                    Text("Beginnt neu, wenn das Auto länger als \(minutes) min aus war (änderbar in den Einstellungen).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Ab Start")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") { confirmReset = true }
                        .disabled(!manager.isReady)
                }
            }
            .confirmationDialog("„Ab Start“ zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) { manager.send(.resetStart) }
            }
        }
    }
}
