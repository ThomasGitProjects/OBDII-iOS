# OBD-Display – iOS-App

Begleit-App für das [OBD-Display](https://github.com/ThomasGitProjects/OBDII) (ESP32 mit Display am OBD-II-Dongle
des BYD Tang EV). Die App verbindet sich per Bluetooth Low Energy mit dem ESP32, zeigt Fahrzeugwerte an und
ändert seine Einstellungen. Für die Kernfunktionen des ESP32 ist sie nicht nötig.

- **Bundle ID:** `at.flintech.OBDDisplay`
- **Deployment Target:** iOS 26.0 (Swift 6, Xcode 26 oder neuer)
- **Architektur:** SwiftUI + Core Bluetooth, MVVM, keine externen Abhängigkeiten
- **Protokoll:** „OBD-Link“ Version 1, Spezifikation in
  [`docs/ble_protokoll.md`](https://github.com/ThomasGitProjects/OBDII/blob/main/docs/ble_protokoll.md) im
  Firmware-Repository; Spiegel in [`OBDLinkProtocol.swift`](OBDDisplay/Protocol/OBDLinkProtocol.swift)

## Funktionen

| Tab | Inhalt |
|---|---|
| **Live** | frei wählbare Werte in großen Kacheln, mindestens 1× pro Sekunde aktualisiert; Warnschwellen orange |
| **Ab Start** | Strecke, Fahrzeit, Energie, Durchschnitte und SoC-Verbrauch seit dem Start; zurücksetzen |
| **Werte** | alle Werte nach Gruppen, Aktualisierung alle 5 s |
| **Scan** | DID-Bereich, Vergleichssuche oder Steuergeräte-Suche auslösen; Treffer speichern und als CSV teilen; DIDs zur dauerhaften Abfrage auswählen und in der App umrechnen |
| **Einstellungen** | Dongle-WLAN, Abfragetakt, Standzeit für „Ab Start“, Warnschwellen; Status, Neustart, Kopplungen löschen, Werkseinstellungen |

Die Anzeige in der App ist unabhängig vom Display des ESP32: Der ESP32 fragt zusätzlich ab, was die App
gerade braucht.

## Verbindung

Der ESP32 ist für die Uhrzeit (ohne App) meist schon mit dem iPhone verbunden. Die App übernimmt diese
Verbindung sofort (`retrieveConnectedPeripherals`), sonst verbindet sie sich mit dem zuletzt genutzten
Gerät oder sucht nach dem Service. Nach einem Abbruch verbindet sie sich von selbst neu.

**Erstes Koppeln:** Das Display des ESP32 zeigt einen 6-stelligen Code, den das iPhone abfragt. War das
iPhone schon vorher (ohne Code) gekoppelt, „OBD-Display“ unter *Einstellungen → Bluetooth* einmal ignorieren
und neu koppeln.

## Build

Gebaut wird ausschließlich über GitHub Actions ([`.github/workflows/build-ios.yml`](.github/workflows/build-ios.yml)),
wie im Projekt `iOS-HelloWorld-BLE`. Ohne Signier-Secrets entsteht eine **unsignierte IPA** (Artifact des
Workflow-Laufs). Die wird mit [Sideloadly](https://sideloadly.io) unter Windows mit der eigenen Apple ID
signiert und installiert; mit einer kostenlosen Apple ID läuft sie 7 Tage.

Lokaler Build auf einem Mac:

```bash
xcodebuild -project OBDDisplay.xcodeproj -scheme OBDDisplay -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' archive -archivePath build/OBDDisplay.xcarchive CODE_SIGNING_ALLOWED=NO
```

Die Signierung in der Pipeline (Apple Developer Program) ist im README von `iOS-HelloWorld-BLE` beschrieben;
die Secrets heißen hier gleich.

## App-Icon

`python tools/make_app_icon.py` erzeugt die drei Varianten (Standard, dunkel, getönt) im Asset-Katalog –
nur Standardbibliothek, ca. 45 s je Variante. Motiv: Elektroauto mit Blitz und Funkwellen.
