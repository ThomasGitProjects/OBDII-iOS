import Foundation

/// Einstellungen des ESP32 (docs/ble_protokoll.md 3.5). Schlüssel, Typen und Wertebereiche wie in der Firmware.
struct SettingDefinition: Identifiable, Sendable {
    enum Kind: Sendable {
        case text(maxLength: Int)
        case integer(byteCount: Int, signed: Bool)
        case ipv4
    }

    var key: UInt8
    var title: String
    var kind: Kind
    var range: ClosedRange<Int>
    var unit: String = ""
    var help: String = ""
    /// Verbindungseinstellung: wird erst nach Bestätigung übernommen.
    var isConnection = false
    var isWriteOnly = false
    var isReadOnly = false

    var id: UInt8 { key }

    static let all: [SettingDefinition] = [
        .init(key: 0x01, title: "WLAN-Name (SSID)", kind: .text(maxLength: 32), range: 1...32,
              help: "WLAN des OBD-Dongles", isConnection: true),
        .init(key: 0x02, title: "WLAN-Passwort", kind: .text(maxLength: 64), range: 0...64,
              help: "leer = offenes WLAN", isConnection: true, isWriteOnly: true),
        .init(key: 0x03, title: "Passwort gesetzt", kind: .integer(byteCount: 1, signed: false), range: 0...1,
              isReadOnly: true),
        .init(key: 0x04, title: "Dongle-IP", kind: .ipv4, range: 0...0,
              help: "leer bzw. 0.0.0.0 = automatisch (Gateway des WLAN)", isConnection: true),
        .init(key: 0x05, title: "Dongle-Port", kind: .integer(byteCount: 2, signed: false), range: 1...65535,
              isConnection: true),
        .init(key: 0x10, title: "Standzeit für „Ab Start“", kind: .integer(byteCount: 2, signed: false),
              range: 5...1440, unit: "min", help: "So lange muss das Auto aus sein, bis „Ab Start“ neu beginnt."),
        .init(key: 0x11, title: "Werte veraltet nach", kind: .integer(byteCount: 2, signed: false),
              range: 500...60000, unit: "ms"),
        .init(key: 0x12, title: "Live-Takt mindestens", kind: .integer(byteCount: 2, signed: false),
              range: 100...1000, unit: "ms", help: "Kleinster Abstand der Live-Aktualisierungen"),
        .init(key: 0x13, title: "Pause zwischen Abfragerunden", kind: .integer(byteCount: 2, signed: false),
              range: 0...2000, unit: "ms"),
        .init(key: 0x14, title: "Langsame Werte je Runde", kind: .integer(byteCount: 1, signed: false), range: 1...10),
        .init(key: 0x15, title: "Zeitzone (Ersatz)", kind: .text(maxLength: 47), range: 1...47,
              help: "POSIX-TZ, gilt nur bis zur ersten Zeit vom iPhone"),
        .init(key: 0x20, title: "Warnung Akkutemperatur über", kind: .integer(byteCount: 1, signed: true),
              range: -40...80, unit: "°C"),
        .init(key: 0x21, title: "Warnung Zelldrift über", kind: .integer(byteCount: 2, signed: false),
              range: 1...500, unit: "mV"),
        .init(key: 0x22, title: "Warnung SoC unter", kind: .integer(byteCount: 1, signed: false),
              range: 0...100, unit: "%"),
    ]

    static func definition(for key: UInt8) -> SettingDefinition? {
        all.first { $0.key == key }
    }

    /// Wert als Text für das Eingabefeld.
    func text(from value: Data) -> String {
        let bytes = [UInt8](value)
        switch kind {
        case .text:
            return String(decoding: bytes, as: UTF8.self)
        case .ipv4:
            guard bytes.count == 4, bytes != [0, 0, 0, 0] else { return "" }
            return bytes.map(String.init).joined(separator: ".")   // Netzwerk-Byte-Reihenfolge
        case .integer(let byteCount, let signed):
            guard bytes.count == byteCount else { return "" }
            var raw = 0
            for (i, b) in bytes.enumerated() { raw |= Int(b) << (8 * i) }
            if signed, byteCount == 1, raw > 127 { raw -= 256 }
            return String(raw)
        }
    }

    /// Eingabe als Wert für den ESP32, oder eine Fehlermeldung.
    func encode(_ text: String) -> Result<Data, SettingInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .text(let maxLength):
            let bytes = Data(trimmed.utf8)
            guard bytes.count >= range.lowerBound, bytes.count <= maxLength else {
                return .failure(.init(message: "Länge \(range.lowerBound)–\(maxLength) Zeichen"))
            }
            return .success(bytes)
        case .ipv4:
            if trimmed.isEmpty { return .success(Data([0, 0, 0, 0])) }
            let parts = trimmed.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { return .failure(.init(message: "IPv4-Adresse, z. B. 192.168.0.10")) }
            return .success(Data(parts))
        case .integer(let byteCount, _):
            guard let value = Int(trimmed), range.contains(value) else {
                return .failure(.init(message: "Zahl von \(range.lowerBound) bis \(range.upperBound)"))
            }
            let raw = UInt32(bitPattern: Int32(value))
            return .success(Data((0..<byteCount).map { UInt8((raw >> (8 * UInt32($0))) & 0xFF) }))
        }
    }

    /// TLV-Folge (Schlüssel, Länge, Wert) lesen.
    static func parseTLV(_ data: Data) -> [UInt8: Data] {
        var r = ByteReader(data)
        var values: [UInt8: Data] = [:]
        while let key = r.u8(), let length = r.u8(), let bytes = r.bytes(Int(length)) {
            values[key] = Data(bytes)
        }
        return values
    }

    static func tlv(key: UInt8, value: Data) -> Data {
        var data = Data([key, UInt8(value.count)])
        data.append(value)
        return data
    }
}

struct SettingInputError: Error, Sendable {
    var message: String
}
