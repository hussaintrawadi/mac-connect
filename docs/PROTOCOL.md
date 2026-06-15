# Wire protocol

Mac Connect uses [Protocol Buffers](https://protobuf.dev/) (proto3) over a single TCP
connection. The canonical schema is **`Shared/proto/messages.proto`**.

## Framing

Each message is sent as:

```
┌────────────────────┬─────────────────────────────┐
│ length (4 bytes BE) │ serialized Envelope bytes   │
└────────────────────┴─────────────────────────────┘
```

`MessageTransport` on both sides reads the 4‑byte big‑endian length, then reads exactly
that many bytes and parses them into an `Envelope`.

## The Envelope

Every message is wrapped in an `Envelope` whose `oneof payload` selects the type. The
receiver switches on which field is set and dispatches to the matching component.

```proto
message Envelope {
  uint64 sequence = 1;
  uint64 timestamp_ms = 2;
  oneof payload {
    // ... one of the messages below ...
  }
}
```

## Message catalogue

Field numbers are grouped by area. **Direction** is the typical sender → receiver.

| # | Message | Direction | Purpose |
|---|---------|-----------|---------|
| 10–13 | `Handshake`, `HandshakeResponse`, `Heartbeat`, `Ack` | both | session setup & keep‑alive |
| 20 | `NotificationEvent` | phone → Mac | a posted notification (app name, title, body, icon) |
| 21 | `NotificationAction` | Mac → phone | dismiss / reply / mark‑read |
| 30–33 | `SmsConversation`, `SmsMessage`, `SmsSend`, `SmsDeliveryStatus` | both | SMS sync & sending |
| 40 | `ClipboardSync` | both | text / url / image clipboard |
| 41 | `UrlHandoff` | both | open a URL on the other device |
| 50–56 | `FileList*`, `FileDownload*`, `FileUpload*`, `FileChunk`, `FileTransfer*` | both | file browsing & transfer |
| 60–61 | `VideoConfig`, `VideoFrame` | phone → Mac | H.264 screen stream |
| 70–72 | `TouchEvent`, `KeyEvent`, `ScrollEvent` | Mac → phone | input injection |
| 80–82 | `CallEvent`, `CallControl`, `CallAudioChunk` | both | call state & control |
| 90–91 | `MediaState`, `MediaControl` | both | phone media now‑playing & control |
| 100–103 | `ContactList`, `ContactRequest`, `CallLogList`, `CallLogRequest` | both | contacts & call history |
| 110 | `DeviceInfo` | phone → Mac | name, OS, battery, screen size |
| 120–121 | `GalleryRequest`, `GalleryResponse` | both | paged photos/videos |
| 122 | `ConnectionControl` | Mac → phone | `DISCONNECT`, `START_MIRROR` |
| 123–126 | `MacControl`, `MacStatus`, `MacMediaState`, `MacMediaControl` | both | control the Mac from the phone |
| 127–128 | `GalleryAlbumsRequest`, `GalleryAlbumsResponse` | both | gallery folders |
| 129–130 | `FileOperation`, `FileOperationResult` | both | new folder / rename / delete |

### A few key enums

```proto
message MacControl {            // phone → Mac
  enum Action { LOCK; RING; STOP_RING; SET_VOLUME; MUTE; UNMUTE;
                WIFI_ON; WIFI_OFF; SLEEP; SET_BRIGHTNESS; BT_ON; BT_OFF; }
  Action action = 1;
  int32  value  = 2;            // SET_VOLUME / SET_BRIGHTNESS (0–100)
}

message ConnectionControl {     // Mac → phone
  enum Action { DISCONNECT; START_MIRROR; }
  Action action = 1;
}

message FileOperation {         // Mac → phone
  enum Op { CREATE_DIR; RENAME; DELETE; }
  Op op = 1; string path = 2; string name = 3;
}
```

See the `.proto` file for the full set of fields on every message.

## Regenerating code after editing the schema

The schema lives in **two places** that must be kept in sync:

- `Shared/proto/messages.proto` — canonical; `option java_multiple_files = true`.
- `AndroidApp/app/src/main/proto/messages.proto` — identical messages, but with
  `option java_multiple_files = false;` and `option java_outer_classname = "Messages";`
  (so Android references them as `Messages.Foo`).

When you change one, mirror the change into the other, then regenerate the Mac's Swift:

```bash
# Mac (Swift) — requires protobuf + swift-protobuf (e.g. `brew install protobuf swift-protobuf`)
protoc --swift_out=MacApp/AndroidBridge/Sources/Generated \
       --proto_path=Shared/proto Shared/proto/messages.proto
```

Android regenerates its Java automatically during the Gradle build (protobuf plugin), so
no manual step is needed there.

### Conventions
- **Never reuse or renumber an existing field** — only add new field numbers. This keeps
  old and new builds compatible.
- `swift_prefix = "AB"` means `Envelope` becomes `ABEnvelope` in Swift, `MacControl`
  becomes `ABMacControl`, etc.
- swift‑protobuf appends `_p` to bool fields whose name starts with `has_`
  (`has_media` → `hasMedia_p`).
