# Contributing to Mac Connect

Thanks for your interest! This project is a personal-scale, fully local Mac ↔ Android
bridge — contributions that keep it simple, private, and dependency-light are the most
welcome.

## Getting started

1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the lay of the land.
2. Follow [docs/BUILDING.md](docs/BUILDING.md) to build both apps.
3. Pick an issue (or open one first for bigger changes so we can discuss the approach).

## Ground rules

- **No cloud, no telemetry, no accounts.** Anything that sends user data off the local
  network will not be merged.
- **Both sides of the protocol.** If you add or change a message in
  `Shared/proto/messages.proto`, mirror it in `AndroidApp/app/src/main/proto/messages.proto`,
  regenerate the Swift (see [docs/PROTOCOL.md](docs/PROTOCOL.md)), and implement **both**
  the sender and the receiver. Never renumber existing fields.
- **Match the existing style.** SwiftUI + small feature classes on the Mac; Kotlin bridges
  on Android. Keep features self-contained.
- **Graceful degradation.** Features that depend on permissions or private APIs must
  no-op cleanly when unavailable — never crash.

## Pull requests

- Keep PRs focused on one change.
- Confirm both apps build:
  - `cd AndroidApp && ./gradlew assembleDebug`
  - `cd MacApp && xcodegen generate && xcodebuild -project AndroidBridge.xcodeproj -scheme AndroidBridge build`
- Describe what you tested on real hardware (Mac + Android versions).

## Reporting bugs

Open an issue with:
- macOS and Android versions (and phone model — OEM skins like MIUI behave differently),
- what you did, what you expected, what happened,
- relevant logs (`Console.app` for the Mac; `adb logcat` for Android).

## Security

If you find a security issue (remember: this app moves SMS, files, and screen contents
across the LAN), please report it privately via a GitHub security advisory rather than a
public issue.
