<div align="center">

# Mac Connect

**Make your Android phone feel like it belongs to your Mac.**

Mirror your screen, take calls, read and send texts, browse files, view your gallery,
share your clipboard, and control your Mac from your phone — all over your own Wi-Fi.
No cloud. No accounts. No tracking. 100% local and free.

[Features](#features) · [How it works](#how-it-works) · [Install](#install) ·
[Build from source](docs/BUILDING.md) · [Architecture](docs/ARCHITECTURE.md) · [Protocol](docs/PROTOCOL.md)

</div>

---

## What is this?

Mac Connect is two apps that talk directly to each other on your local network:

- **Mac app** — a menu‑bar + window app written in Swift / SwiftUI (macOS 13+).
- **Android app** — a companion app written in Kotlin (Android 8.0 / API 26+).

They discover each other with mDNS (Bonjour), pair once via a QR code, and then exchange
everything over a single TCP connection using Protocol Buffers. Your messages, calls,
files, screen and clipboard **never leave your network** — there is no server in the middle.

It's inspired by the seamless feel of the Apple ecosystem (Continuity, Phone Link), but
built to be open, free, and fully under your control.

## Features

### Screen mirroring & control
- Live H.264 screen mirror of your phone on your Mac.
- Full control with your **mouse and keyboard**: tap, click‑drag to swipe, two‑finger
  scroll, type into text fields.
- Right‑click menu for **Back / Home / Recents / Notifications**, directional swipes,
  **Wake Screen** and **Lock Phone** (power‑button equivalents).
- Type your **lock‑screen / app‑lock PIN** from the Mac keyboard.
- Keep‑awake overlay so the phone screen stays on while you're using it.
- Opening the mirror on the Mac is gated by **Touch ID**.

### Calls & dialer
- A phone view on the Mac with **Contacts, Recents (real call history) and a Dial Pad**.
- Type numbers straight from the Mac keyboard.
- **Incoming‑call pop‑up** on the Mac with Answer / Decline, and a ringtone.
- Place calls from the Mac; control mute and hang‑up.

### Messages
- Read and reply to **SMS** from the Mac, in real time, with contact names.

### Files
- Browse your phone's storage like Finder: **Quick Look previews** (Space), image/video
  thumbnails, **New Folder / Rename / Delete**.
- **Drag files in and out** between Finder and the phone, plus ⌘C / ⌘V.

### Gallery
- Your phone's **photos and videos** on the Mac, organised into folders
  (All Media, Videos, Camera, Screenshots, WhatsApp, …).

### Notifications
- Phone notifications mirrored to the Mac with the **real app name and icon**,
  and they respect macOS **Focus / Do Not Disturb**.

### Clipboard
- **Copy‑paste across devices**, including **images** in both directions.

### Media
- Control **phone playback** from the Mac and **Mac playback** (Music, Spotify, or any
  app via media keys — YouTube in a browser, etc.) from the phone.

### Control your Mac from your phone
- Volume, **brightness**, Wi‑Fi, **Bluetooth**, lock, sleep, and a find‑my‑Mac sound.
- Live **Mac battery** on the phone and live **phone battery** on the Mac.

### Always connected
- Pair once. After that the apps reconnect automatically whenever they're on the same
  Wi‑Fi — like a Bluetooth device — without re‑scanning the QR code.

## How it works

```
┌──────────────┐        mDNS discovery (_androidbridge._tcp)        ┌──────────────┐
│   Mac app    │  ◀───────────────────────────────────────────────▶ │ Android app  │
│ (SwiftUI)    │                                                     │  (Kotlin)    │
│              │        TCP + Protocol Buffers (one socket)          │              │
│  features ◀──┼────────────  envelope.oneof routing  ──────────────┼──▶ bridges   │
└──────────────┘                                                     └──────────────┘
        ▲                                                                    ▲
        └──────── QR pairing (one time): keys exchanged over TCP ───────────┘
```

- **Pairing:** the Mac shows a QR code containing its IP(s) and a port. The phone scans
  it, connects, and the two exchange device IDs / public‑key fingerprints over TCP.
- **Discovery & reconnect:** the phone advertises itself over mDNS; the Mac browses for it
  and connects. If mDNS is quiet, the Mac direct‑dials the phone's last known IP.
- **Transport:** every message is a `protobuf` `Envelope` with a `oneof payload`, sent
  length‑prefixed over a single TCP connection. See [docs/PROTOCOL.md](docs/PROTOCOL.md).

A full breakdown lives in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Privacy

Everything is peer‑to‑peer on your LAN. There is **no backend, no account, no telemetry**.
The only data that crosses the wire is what you ask for (a notification, a file you open,
the screen while you mirror), and it goes straight to your other device and nowhere else.

## Install

> Pre‑built releases are published on the repo's **Releases** page. You can also
> [build from source](docs/BUILDING.md).

1. **Mac** — open `MacConnect-x.y.z.dmg` and drag **Mac Connect** to Applications.
   On first launch, allow Local Network, Camera, Microphone and (optionally) Notifications.
2. **Android** — install `MacConnect-x.y.z.apk`. Grant the permissions during onboarding
   (Messages, Contacts, Phone, Photos & Media, Notification access, Accessibility, and
   "Display over other apps"). Everything is explained on the in‑app privacy screen.
3. **Pair** — open Mac Connect on the Mac (it shows a QR code), then on the phone tap
   *Pair with Mac* and scan it. Both devices must be on the same Wi‑Fi network.

> **Note on sideloading:** because this app intentionally uses sensitive permissions
> (SMS, call log, accessibility) and is installed outside the Play Store, Google Play
> Protect may warn about it. That's expected for a self‑hosted tool like this.

## Limitations (by design / OS constraints)

Being upfront about what is **not** possible:

- **Routing live cellular call audio** through the Mac's mic/speaker — blocked by Android
  and macOS for non‑system apps. You can control calls, not pipe their audio.
- **Unlocking the phone with Touch ID from the Mac** — there is no Android API for it.
  You can wake the screen and type your PIN from the Mac keyboard instead.
- **Capturing the secure lock screen** — Android blocks screen capture of secure surfaces,
  so the lock screen shows black in the mirror (you can still type the PIN blind).
- **Connection is plain TCP on the LAN** (no TLS yet) — fine for a trusted home network.
- **Clipboard phone → Mac** only syncs while the phone app is foregrounded (Android 10+
  restriction).

## Build from source

See **[docs/BUILDING.md](docs/BUILDING.md)** for prerequisites and step‑by‑step
instructions for both apps, regenerating the protocol, and packaging releases.

## Documentation

| Doc | What's in it |
|-----|--------------|
| [docs/FEATURES.md](docs/FEATURES.md) | Every feature, what it does, and its caveats |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Project layout, connection model, components |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The wire protocol and message catalog |
| [docs/BUILDING.md](docs/BUILDING.md) | Build, sign, and package both apps |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |

## Contributing

Contributions are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) — free to use, modify, and distribute.
