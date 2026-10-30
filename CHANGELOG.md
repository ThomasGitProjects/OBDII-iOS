# Changelog

Jede Version entspricht einem Build von GitHub Actions. Die Versionsnummer ist die Laufnummer des Workflows,
die IPA liegt lokal als `.artifacts/OBDDisplay-unsigned-<Version>.ipa`.

## Version 6 – 30.10.2026

- Verbindung kommt jetzt auch zustande, wenn die App vor der Bluetooth-Verbindung des iPhones zum ESP32 gestartet
  wird. Vorher blieb sie bei „Suche OBD-Display“ hängen: iOS verbindet den gekoppelten ESP32 selbst, danach sendet
  er kein Advertising mehr und der Scan der App fand ihn nie. Die App prüft nun, solange keine Verbindung
  besteht, alle 2 s, ob iOS ein passendes Gerät verbunden hat, und übernimmt es.
- Dasselbe gilt nach einem Verbindungsabbruch (z. B. Neustart des ESP32).

## Version 5 – 30.10.2026 (Commit `e8af0c7`)

- Keine Änderung an der App, nur dieses Changelog hinzugefügt.

## Version 4 – 30.10.2026 (Commit `fd47c8b`)

- Die Tastatur verschwindet beim Tippen außerhalb eines Eingabefelds, beim Scrollen und beim Tabwechsel.
  Vorher verdeckte sie die Tab-Leiste, weil die Ziffernblöcke keine Return-Taste haben.
- „Fertig“-Taste über der Tastatur in den Einstellungen und im Formular „DID hinzufügen/bearbeiten“.

## Version 3 – 30.10.2026 (Commit `6c2c737`)

- Robusteres Verbinden: Die App prüft der Reihe nach alle Geräte, die iOS als verbunden meldet (HID- und
  Geräteinfo-Service), „OBD-Display“ zuerst. Geräte ohne OBD-Link-Service werden übersprungen. Vorher blieb die
  App bei „Suche OBD-Display“ hängen, wenn iOS das Gerät unter altem Namen oder mit veralteter Gerätestruktur
  kannte.
- Während der Suche zeigt das Banner, welche Geräte laut iOS verbunden sind.
- Hinweis mit Abhilfe (in iOS ignorieren und neu koppeln), wenn „OBD-Display“ verbunden ist, aber keinen
  OBD-Link-Service meldet.

## Version 2 – 30.10.2026 (Commit `3cae007`)

- Keine Änderung an der App. Der Ordner `.artifacts/` wird von git ignoriert.

## Version 1 – 30.10.2026 (Commit `c4b04c2`)

Erste Version der App:

- Verbindung zum ESP32 über die bestehende Bluetooth-Kopplung (HID-Tarnung), gespeicherte Geräte-ID oder Scan;
  automatisches Neuverbinden.
- **Live:** frei wählbare Werte, mindestens einmal pro Sekunde aktualisiert.
- **Ab Start:** Strecke, Fahrzeit, Verbrauch, Rekuperation, SoC-Verbrauch und Energie seit dem Start.
- **Werte:** alle Werte des ESP32, nach Gruppen.
- **Scan:** DID-Suche, ECU-Scan und Bereichs-Scan auslösen, Ergebnisse speichern und als CSV exportieren; frei
  gewählte DIDs dauerhaft abfragen lassen, mit Umrechnung in der App.
- **Einstellungen:** Verbindung zum Dongle (mit Bestätigung und automatischer Rücknahme), Abfrage, Standzeit für
  „Ab Start“, Warnschwellen, Gerätestatus und Befehle (Trip/„Ab Start“ zurücksetzen, Neustart, Kopplungen
  löschen, Werkseinstellungen).
- App-Icon: Elektroauto mit Blitz und Funkwellen.
