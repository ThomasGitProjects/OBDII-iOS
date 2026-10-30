import SwiftUI
import UIKit

/// Live-Ansicht (A-VAL-01…05): frei wählbare Werte in großen Kacheln, aktualisiert mindestens 1× pro Sekunde.
struct LiveView: View {
    @Environment(OBDLinkManager.self) private var manager
    @Environment(AppPreferences.self) private var preferences
    @State private var editing = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                ConnectionBanner()
                StatusStrip()
                    .padding(.horizontal)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(preferences.liveValueNames, id: \.self) { name in
                        ValueTile(name: name, entry: manager.entry(named: name))
                    }
                }
                .padding()
            }
            .navigationTitle("Live")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Auswahl", systemImage: "slider.horizontal.3") { editing = true }
                }
            }
            .sheet(isPresented: $editing) {
                LiveSelectionView()
            }
        }
    }
}

/// Kurzstatus des ESP32 (A-VAL-04)
struct StatusStrip: View {
    @Environment(OBDLinkManager.self) private var manager

    var body: some View {
        if manager.isReady {
            let status = manager.status
            HStack(spacing: 14) {
                indicator("Dongle", "wifi", status.dongleConnected)
                indicator("Fahrzeug", "bolt.car", status.vehicleLive)
                indicator("Zeit", "clock", status.timeSynced)
                Spacer()
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
        }
    }

    private func indicator(_ label: String, _ symbol: String, _ on: Bool) -> some View {
        Label(label, systemImage: symbol)
            .labelStyle(.iconOnly)
            .foregroundStyle(on ? Color.green : Color.secondary)
            .accessibilityLabel("\(label) \(on ? "ja" : "nein")")
    }
}

struct ValueTile: View {
    @Environment(OBDLinkManager.self) private var manager
    let name: String
    let entry: CatalogEntry?

    var body: some View {
        let sample = entry.flatMap { manager.values[$0.id] }
        let warning = entry.map { manager.isWarning($0) } ?? false
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ValueText.number(sample, entry))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(entry?.unit ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if sample?.status == .stale {
                Text("veraltet")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .foregroundStyle(sample?.status == .valid ? Color.primary : Color.secondary)
        .background(warning ? Color.orange.opacity(0.25) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Auswahl der Live-Werte aus dem Katalog, nach Gruppen.
struct LiveSelectionView: View {
    @Environment(OBDLinkManager.self) private var manager
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if manager.catalog.isEmpty {
                    Text("Der Werte-Katalog wird beim Verbinden geladen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(ValueGroup.allCases) { group in
                    let entries = manager.catalog.filter { $0.group == group }
                    if !entries.isEmpty {
                        Section(group.title) {
                            ForEach(entries) { entry in
                                Button {
                                    toggle(entry.name)
                                } label: {
                                    HStack {
                                        Text(entry.name).foregroundStyle(.primary)
                                        Spacer()
                                        if preferences.liveValueNames.contains(entry.name) {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Live-Werte")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(preferences.liveValueNames.count)/64")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggle(_ name: String) {
        if let index = preferences.liveValueNames.firstIndex(of: name) {
            preferences.liveValueNames.remove(at: index)
        } else if preferences.liveValueNames.count < 64 {
            preferences.liveValueNames.append(name)
        }
    }
}
