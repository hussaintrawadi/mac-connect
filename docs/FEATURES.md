# Features in detail

A developer‑oriented tour of everything Mac Connect does, how it's implemented, and the
caveats for each area.

---

## Pairing & connection

- **QR pairing.** The Mac opens an `NWListener` on a fixed port (47291) and renders a QR
  containing `{ version, mac id, ip, ips[], port }`. The Android app scans it with a custom
  full‑screen camera screen (ZXing `CaptureManager` + `DecoratedBarcodeView`) and connects.
  Keys/ids are exchanged over TCP; the QR is never needed again.
- **Auto‑reconnect.** Android advertises over mDNS and the Mac browses for it. If mDNS is
  quiet, the Mac direct‑dials the phone's last known IP (port derived from the Mac id). On
  Wi‑Fi change, Android re‑advertises so the two re‑link automatically.
- **Connect / Disconnect** on the phone is the primary action once paired; **Unpair** is a
  separate, confirmed action. Disconnecting keeps the pairing — reconnect needs no QR.
- *Caveat:* plain TCP on the LAN (no TLS yet).

## Screen mirroring & control

- **Video.** Android captures the screen with `MediaProjection` and encodes H.264 with
  `MediaCodec`; the Mac decodes with VideoToolbox into an `AVSampleBufferDisplayLayer`. The
  window auto‑sizes to the phone's aspect ratio.
- **Input.** Mouse and trackpad become touch: click = tap, click‑drag = swipe, two‑finger
  scroll = scroll. A `TouchEvent`/`ScrollEvent`/`KeyEvent` stream drives an Android
  `AccessibilityService` (`TouchInjectionService`) that dispatches gestures and injects text.
- **Right‑click menu:** Tap, Long Press, four directional swipes, Back / Home / Recent Apps /
  Notifications, **Wake Screen** and **Lock Phone**.
- **Keyboard:** type into focused fields; arrows move the cursor; Backspace/Return handled.
  Placeholder/hint text is never treated as real text.
- **Lock‑screen PIN.** With no focused field (keyguard/app‑lock), typed characters click the
  matching on‑screen keypad buttons, so you can enter your PIN from the Mac keyboard.
- **Keep‑awake.** A 1×1 `FLAG_KEEP_SCREEN_ON` overlay keeps the phone awake while mirroring
  (needs "Display over other apps").
- **Touch ID gate.** Opening the mirror on the Mac requires Touch ID / password
  (`LocalAuthentication`), and the Mac asks the phone to start capture automatically.
- *Caveats:* Android requires a one‑tap capture‑consent each session (no app can skip it);
  the secure lock screen renders black in the mirror (OS blocks capture of secure surfaces).

## Calls & dialer

- **Phone view** with Contacts, **Recents** (real call log via `CallLog.Calls`), and a
  **Dial Pad** you can type into from the Mac keyboard.
- **Incoming call** raises a floating HUD on the Mac with Answer / Decline and a looping
  ringtone; call state comes from a phone‑side `CallStateMonitor`, controlled via
  `TelecomManager`.
- Dial from the Mac (`CallControl.DIAL` → `ACTION_CALL`), mute, hang up.
- *Caveat:* live call **audio** cannot be routed through the Mac (OS restriction); this is
  call control, not a softphone. DTMF tones mid‑call need an `InCallService` (not yet built).

## Messages (SMS)

- Conversations and threads are read from the SMS `ContentResolver`; new messages arrive in
  real time via an `SmsReceiver`. Reply from the Mac (`SmsSend` → `SmsManager`), with
  contact‑name resolution and delivery status.

## Files

- Browse phone storage with a Finder‑like table. Listing merges `File.listFiles()` with a
  `MediaStore` fallback so media shows even without all‑files access.
- **Image/video thumbnails** are attached to entries (bounded per folder for speed).
- **Quick Look** preview on Space / context menu (downloads to a temp file, then
  `quickLookPreview`).
- **New Folder / Rename / Delete** via `FileOperation` (applied on the phone, then a
  `MediaScanner` refresh).
- **Drag in/out** between Finder and the phone, plus ⌘C / ⌘V (download‑on‑demand promises).

## Gallery

- Photos **and** videos from `MediaStore.Files`, paged, with JPEG thumbnails and video
  thumbnails. Shown as folders first (virtual **All Media** + **Videos**, plus real buckets
  like Camera, Screenshots, WhatsApp), then a grid inside each.

## Notifications

- A `NotificationListenerService` forwards notifications with the **resolved app label and
  icon** (`QUERY_ALL_PACKAGES` so names aren't raw package ids). On the Mac they post via
  `UserNotifications` at `.active` interruption level, so **Focus / Do Not Disturb** filters
  them like any other app. Reply / dismiss actions are supported where the source allows.

## Clipboard

- Text, URLs and **images** sync both directions. Android reads copied images from
  `content://` URIs and ships them as PNG; Mac images are written to cache and placed on the
  clipboard via a `FileProvider` URI. The Mac reads PNG/TIFF from `NSPasteboard`.
- *Caveat:* phone → Mac only works while the phone app is foregrounded (Android 10+ limit).

## Media control (both directions)

- **Phone media** now‑playing and controls come from `MediaSessionManager` (needs
  notification access) and show on the Mac.
- **Mac media** is controlled from the phone: Music/Spotify via AppleScript, and **anything
  else** (YouTube in a browser, VLC, …) via system **media‑key events** when no scriptable
  player is running.

## Control your Mac from the phone

- **Volume** (slider sheet), **Brightness** (slider sheet), **Wi‑Fi** and **Bluetooth**
  toggles in a Control‑Center‑style 2×2 grid, plus **Lock**, **Sleep**, and a
  **find‑my‑Mac** sound.
- Volume via AppleScript, Wi‑Fi via `networksetup`, sleep via `pmset`. **Brightness** and
  **Bluetooth** use private system framework symbols resolved at runtime with `dlopen`
  (DisplayServices/CoreDisplay and IOBluetooth) — guarded so a missing symbol can never
  crash the app, and Bluetooth requires `NSBluetoothAlwaysUsageDescription`.
- Live **Mac battery** on the phone and live **phone battery** on the Mac (sent with the
  heartbeat / `DeviceInfo`).

## Menu bar & Dock

- The Mac lives in the menu bar with a custom popover (status, feature tiles, now‑playing,
  battery). The **Dock right‑click menu** jumps straight to Mirror / Messages / Files /
  Gallery / Phone.

---

### Summary of hard limitations

| Want | Why it's not possible |
|------|----------------------|
| Hear/speak call audio through the Mac | Android & macOS block non‑system apps from cellular call audio |
| Unlock the phone with Mac Touch ID | No Android API exposes biometric unlock to apps |
| See the secure lock screen in the mirror | Android blocks screen capture of secure surfaces |
| Skip the phone's screen‑capture tap | Android enforces consent for every capture session |
