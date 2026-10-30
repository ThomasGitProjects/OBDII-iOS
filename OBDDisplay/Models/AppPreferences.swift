import Foundation
import Observation

/// Einstellungen, die nur die App betreffen: Auswahl der Live-Ansicht und Umrechnungen der frei gewählten DIDs.
/// Werte werden über ihren Namen gemerkt, weil sich die Wert-IDs zwischen Firmwareversionen ändern können.
@MainActor
@Observable
final class AppPreferences {
    var liveValueNames: [String] {
        didSet { UserDefaults.standard.set(liveValueNames, forKey: Self.liveKey) }
    }

    private(set) var conversions: [String: DIDConversion] {
        didSet {
            if let data = try? JSONEncoder().encode(conversions) {
                UserDefaults.standard.set(data, forKey: Self.conversionsKey)
            }
        }
    }

    private static let liveKey = "liveValueNames"
    private static let conversionsKey = "didConversions"

    /// Vorauswahl für die Live-Ansicht (Namen aus dem Werte-Katalog der Firmware).
    static let defaultLiveValues = ["Geschwindigkeit", "Akkuleistung", "SoC", "Ist-Verbrauch", "Temperatur",
                                    "Zelldrift"]

    init() {
        liveValueNames = UserDefaults.standard.stringArray(forKey: Self.liveKey) ?? Self.defaultLiveValues
        if let data = UserDefaults.standard.data(forKey: Self.conversionsKey),
           let saved = try? JSONDecoder().decode([String: DIDConversion].self, from: data) {
            conversions = saved
        } else {
            conversions = [:]
        }
    }

    func conversion(for key: DIDKey) -> DIDConversion? {
        conversions[key.text]
    }

    func setConversion(_ conversion: DIDConversion?, for key: DIDKey) {
        conversions[key.text] = conversion
    }
}
