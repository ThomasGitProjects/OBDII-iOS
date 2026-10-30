import Foundation
import Observation

/// Treffer der DID-/ECU-Scans (Z-05). Bleiben über App-Neustarts erhalten (JSON in Application Support) und
/// lassen sich als CSV exportieren. Ein neuer Treffer für dieselbe DID ersetzt den alten.
@MainActor
@Observable
final class ScanStore {
    private(set) var hits: [ScanHit] = []

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan_hits.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([ScanHit].self, from: data) {
            hits = saved
        }
    }

    var sortedHits: [ScanHit] {
        hits.sorted { ($0.header, $0.did) < ($1.header, $1.did) }
    }

    func add(_ hit: ScanHit) {
        if let index = hits.firstIndex(where: { $0.id == hit.id }) {
            hits[index] = hit
        } else {
            hits.append(hit)
        }
        scheduleSave()
    }

    func removeAll() {
        hits = []
        scheduleSave()
    }

    /// Speichert gebündelt (ein Scan liefert viele Treffer schnell hintereinander).
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = hits
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// CSV-Datei im temporären Ordner für das Teilen-Menü.
    func exportCSV() -> URL? {
        var csv = "Steuergeraet;DID;Ergebnis;NRC;Laenge;Bytes;Zeit\n"
        let formatter = ISO8601DateFormatter()
        for hit in sortedHits {
            let result = hit.isECU ? "ECU" : (hit.isNegative ? "abgelehnt" : "Daten")
            let nrc = hit.isNegative ? String(format: "%02X", hit.nrc) : ""
            csv += String(format: "%03X;%04X;", hit.header, hit.did)
            csv += "\(result);\(nrc);\(hit.bytes.count);\(hit.bytes.hexString);\(formatter.string(from: hit.date))\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OBD-Scan.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
