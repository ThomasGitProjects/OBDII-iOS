# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`OBDDisplay`: SwiftUI + CoreBluetooth companion app (iOS 26.0, Swift 6 language mode, no third-party
dependencies) for the ESP32 firmware in `D:\gitProjects\OBDII` (GitHub `ThomasGitProjects/OBDII`). Bundle ID
`at.flintech.OBDDisplay`. User-facing docs and UI strings are German.

The BLE protocol ("OBD-Link", version 1) is specified in the firmware repo, `docs/ble_protokoll.md`. That
document is authoritative; `OBDDisplay/Protocol/OBDLinkProtocol.swift` mirrors it. Change both together.

## Building

The checkout lives on Windows, so there's no local Xcode. **GitHub Actions is the only build path**
(`.github/workflows/build-ios.yml`, copied from `D:\GitHub\iOS-HelloWorld-BLE`). Treat changes as unverified
until a workflow run passes; read failures with `gh run view <id> --log-failed`. Without signing secrets the
workflow produces an unsigned IPA that the user installs with Sideloadly.

After a successful run, download the IPA to `.artifacts/OBDDisplay-unsigned-<run number>.ipa` (git-ignored).
Never delete older IPAs there. Add an entry for each new version to `CHANGELOG.md` (German, newest first).

App icon PNGs come from `python tools/make_app_icon.py` (standard library only, ~45 s per variant). Edit the
script and re-run it instead of editing the PNGs.

## Xcode project

`project.pbxproj` is hand-written (`objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup` for
`OBDDisplay/`), so adding or removing Swift files needs no pbxproj edit. Info.plist is generated; plist keys
are `INFOPLIST_KEY_*` build settings, duplicated in Debug and Release. The shared scheme is required for CI.

## Architecture

- `OBDLinkManager` (`@MainActor @Observable`) owns the `CBCentralManager` (main queue) and all app state.
  Delegate methods are `nonisolated`, extract Sendable values and enter `MainActor.assumeIsolated`; the
  peripheral object is never passed across, the manager keeps its own reference.
- Reads/writes are wrapped as `async` via per-characteristic FIFO continuations (`pendingReads/Writes`).
- Connection: `retrieveConnectedPeripherals` (ESP32 is usually already connected via its HID disguise for the
  time sync), then the saved identifier, then a scan for the service UUID. Reconnect immediately on drop.
- Which values the ESP32 streams depends on the visible tab (`ContentView.updateLiveValues`); other views use
  snapshots. The catalog (value names/units/groups) is cached by CRC; live selection is stored by value name.
