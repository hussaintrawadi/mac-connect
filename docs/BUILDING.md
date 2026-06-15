# Building from source

You can build the two apps independently. The Mac app needs a Mac with Xcode; the Android
app needs the Android SDK and JDK 17.

## Prerequisites

| Tool | Used for | Install |
|------|----------|---------|
| Xcode 16+ | Mac app | App Store |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | generates the `.xcodeproj` | `brew install xcodegen` |
| protobuf + swift-protobuf | regenerating the protocol (optional) | `brew install protobuf swift-protobuf` |
| Android Studio / Android SDK (API 35) | Android app | [developer.android.com](https://developer.android.com/studio) |
| JDK 17 (Temurin recommended) | Gradle | `brew install --cask temurin@17` |
| Python 3 + Pillow | regenerating the app icon (optional) | `pip install pillow` |

## Android app

```bash
cd AndroidApp

# Point Gradle at JDK 17 and the SDK (adjust paths for your machine)
export JAVA_HOME="/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"

# Debug build → app/build/outputs/apk/debug/app-debug.apk
./gradlew assembleDebug

# Release build → app/build/outputs/apk/release/app-release.apk
./gradlew assembleRelease
```

Or use the helper, which copies a named APK into `dist/`:

```bash
./scripts/build_apk.sh debug      # or: release
```

### Release signing (optional)

By default the **release build falls back to the debug signing key** so anyone can build
it. To sign with your own key, create a keystore and tell Gradle about it — see
[`AndroidApp/keystore/README.md`](../AndroidApp/keystore/README.md). In short:

```bash
keytool -genkeypair -v -keystore AndroidApp/keystore/release.jks \
        -alias myalias -keyalg RSA -keysize 2048 -validity 10000
```

Then either create `AndroidApp/keystore.properties` (gitignored):

```properties
storeFile=keystore/release.jks
storePassword=•••••
keyAlias=myalias
keyPassword=•••••
```

…or set the equivalent environment variables: `MC_KEYSTORE_FILE`, `MC_KEYSTORE_PASSWORD`,
`MC_KEY_ALIAS`, `MC_KEY_PASSWORD`. The keystore and `keystore.properties` are **never**
committed.

## Mac app

```bash
cd MacApp
xcodegen generate            # creates AndroidBridge.xcodeproj from project.yml
xcodebuild -project AndroidBridge.xcodeproj -scheme AndroidBridge \
           -configuration Debug -destination 'platform=macOS' build
```

Open `AndroidBridge.xcodeproj` in Xcode to run/debug interactively, or package a DMG:

```bash
./scripts/build_dmg.sh release    # → dist/MacConnect-x.y.z.dmg
```

The built app is named **`Mac Connect.app`** (the Xcode target/scheme is `AndroidBridge`).
The app is signed ad‑hoc by default; for distribution outside your own machines you'd add
a Developer ID and notarization.

## Regenerating the protocol

If you edit `messages.proto`, see [PROTOCOL.md](PROTOCOL.md#regenerating-code-after-editing-the-schema).

## Regenerating the icon

```bash
python3 scripts/gen_icon.py        # writes Android mipmaps + Mac AppIcon.appiconset
```

## Troubleshooting

- **Gradle fails on a newer JDK** — Gradle here needs **JDK 17**; set `JAVA_HOME` explicitly.
- **`xcodegen: command not found`** — `brew install xcodegen`.
- **Mac app shows a generic icon** — make sure `Assets.xcassets` is built; the icon set is
  declared under `sources` (with `buildPhase: resources`) in `project.yml`.
- **Phone and Mac won't connect** — confirm both are on the **same Wi‑Fi**, that the Android
  Accessibility service is enabled (it's disabled on every reinstall), and that macOS
  allowed Local Network access.
