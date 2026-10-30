import Foundation

/// Umrechnung der Rohbytes einer frei gewählten DID in einen Wert. Liegt nur in der App (der ESP32 liefert
/// Rohbytes): Wert = Rohwert × Faktor + Offset.
struct DIDConversion: Codable, Hashable, Sendable {
    var name = ""
    var startByte = 0           // ab 0
    var length = 1              // 1…4 Byte
    var signed = false
    var littleEndian = true     // BYD liefert little-endian
    var factor = 1.0
    var offset = 0.0
    var unit = ""
    var decimals = 1

    /// Wert aus den Rohbytes, nil wenn zu wenige Bytes da sind.
    func value(from bytes: [UInt8]) -> Double? {
        guard length >= 1, length <= 4, startByte >= 0, startByte + length <= bytes.count else { return nil }
        let slice = Array(bytes[startByte..<startByte + length])
        let ordered = littleEndian ? slice : slice.reversed()
        var raw: Int64 = 0
        for (i, b) in ordered.enumerated() {
            raw |= Int64(b) << (8 * Int64(i))
        }
        if signed {
            let bits = Int64(8 * length)
            if raw & (1 << (bits - 1)) != 0 {
                raw -= 1 << bits
            }
        }
        return Double(raw) * factor + offset
    }

    func formatted(_ bytes: [UInt8]) -> String? {
        guard let value = value(from: bytes) else { return nil }
        let number = value.formatted(.number.precision(.fractionLength(decimals)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}
