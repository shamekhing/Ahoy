# Ahoy

> **Nothing Between** — privacy-first, peer-to-peer chat for people in the same space.

Ahoy is a Flutter app that lets nearby devices discover each other and chat without a server, internet connection, or account. Communication happens entirely on-device over Bluetooth LE, WiFi Direct, or local network (LAN) — whichever is fastest and available.

---

## Recent Updates

- **2026-04-27**: Updated `record` package to version 6.2.0 to fix Linux plugin interface compatibility issues.

---

## How it works

Ahoy uses a three-tier transport stack, automatically choosing the best available channel per conversation:

| Priority | Transport | Range | Media support |
|----------|-----------|-------|---------------|
| 1 | **LAN (same WiFi network)** | ~100m+ | Full — images, voice, files |
| 2 | **WiFi Direct (P2P)** | ~30–100m | Full — images, voice, files |
| 3 | **Bluetooth LE (fallback)** | ~5–50m | Text only |

Each chat header shows a live transport badge so you always know which channel is in use. If the only available transport is BLE, media and voice buttons are blocked with an explanatory prompt.

---

## Features

### Discovery
- **BLE scanning** — finds devices within Bluetooth range advertising the Ahoy service
- **LAN discovery** — UDP broadcast on the local network surfaces peers on the same WiFi automatically, shown in a separate "Same Network" section in the Discover tab
- **QR code pairing** — scan to instantly start a conversation with someone nearby
- **Status broadcasting** — set a short status so others can see what you're up to

### Messaging
- **Text, images, voice** — full media support over LAN and WiFi Direct
- **BLE text fallback** — when no WiFi channel is available, text still works via Bluetooth LE
- **Reply threading** — long-press any message to reply to it
- **Disappearing messages** — per-conversation timer (1 min / 5 min / 1 h / 1 day / off)
- **Conversation branches** — fork a conversation into a named sub-thread; invite others by link or QR

### Privacy & security
- **No server** — no accounts, no cloud, no analytics
- **End-to-end encryption** — RSA-OAEP key exchange + AES message encryption
- **Zero-knowledge age verification** — prove 18+ without revealing your exact age
- **Local storage only** — all data stays on device (SharedPreferences + file system)
- **Biometric lock** — optional fingerprint/face lock on startup

### Profile
- **Display name + optional bio and interests**
- **Gender-aware default avatars** — `icon_male.png` / `icon_female.png` used when no photo is set; custom photo otherwise
- **Short ID** — a 6-character alphanumeric handle (derived from UUID) used for LAN peer addressing and QR codes

---

## Project structure

```
lib/
├── main.dart                        # App entry point
├── Ahoy/
│   ├── ahoy_app.dart                # Main app widget and routing
│   ├── core/
│   │   ├── constants.dart           # App constants
│   │   ├── enums.dart               # Enums used across the app
│   │   └── errors.dart              # Error handling
│   ├── models/
│   │   ├── conversation.dart        # Conversation model
│   │   ├── local_user.dart          # Local user model
│   │   ├── message.dart             # Message model
│   │   ├── nearby_peer.dart         # Nearby peer model
│   │   ├── peer_profile.dart        # Peer profile model
│   ├── providers/
│   │   ├── auth_provider.dart       # Authentication provider
│   │   ├── chat_provider.dart       # Chat provider
│   │   ├── discovery_provider.dart  # Discovery provider
│   │   ├── profile_provider.dart    # Profile provider
│   │   └── transport_provider.dart  # Transport provider
│   ├── router/
│   │   └── ahoy_router.dart         # App routing
│   ├── screens/
│   │   ├── main_shell.dart          # Main shell screen
│   │   ├── root_screen.dart         # Root screen
│   │   ├── auth/                    # Authentication screens
│   │   ├── chat/                    # Chat screens
│   │   ├── discover/                # Discovery screens
│   │   ├── profile/                 # Profile screens
│   │   └── settings/                # Settings screens
│   ├── services/
│   │   ├── transport_manager.dart   # Transport management
│   │   ├── auth/                    # Authentication services
│   │   ├── chat/                    # Chat services
│   │   ├── crypto/                  # Cryptography services
│   │   ├── discovery/               # Discovery services
│   │   ├── media/                   # Media services
│   │   ├── profile/                 # Profile services
│   │   ├── storage/                 # Storage services
│   │   └── transport/               # Transport services
│   └── widgets/
│       ├── auth/                    # Authentication widgets
│       └── ...                      # Other widgets
```
└── widgets/
    ├── chat/                        # MessageList, MessageInputBar, bubbles, …
    ├── common/
    │   ├── profile_avatar.dart      # Gender-aware avatar widget
    │   ├── transfer_progress_indicator.dart
    │   └── wifi_direct_indicator.dart
    └── discovery/                   # PersonCard, StatusSection, CategoryPicker, …
```

---

## Transport detail

### LAN discovery (`LanDiscoveryService`)
- Binds a `RawDatagramSocket` on UDP port **45678** with broadcast enabled
- Broadcasts `{"type":"ahoy_announce","name":"…","shortId":"…","port":45679}` every **5 seconds**
- Ignores self-announcements; expires peers after **20 seconds** of silence
- Emits `Stream<List<LanPeer>>`

### LAN messaging (`LanMessagingService`)
- `ServerSocket` on TCP port **45679** (`shared: true`)
- Newline-delimited JSON framing — one `ChatMessage` JSON per line
- Reuses outbound socket connections per peer address
- Emits `Stream<ChatMessage>` for incoming messages

### Message routing (`MessageRouterService`)
- `canSendMedia({bool isLanAvailable})` — returns `true` when LAN or WiFi Direct is up
- `currentTransportMode({bool isLanAvailable})` — returns the active `TransportMode`
- For messages >50 KB: tries WiFi Direct first; falls back to BLE-compressed thumbnail

### BLE restriction
When `canSendMedia()` returns `false` (BLE-only), the chat UI:
- Shows a blue info banner in the chat header
- Blocks image gallery, camera, and voice recording buttons with an explanatory snackbar
- Continues to send and receive text normally

---

## Getting started

### Requirements
- Flutter **3.x** (tested on 3.41.6 / Dart 3.11)
- Android 8.0+ (API 26) — primary target platform
- Physical Android device for BLE and WiFi Direct (emulators don't support them)

### Run
```bash
flutter pub get
flutter run
```

### Analyze
```bash
flutter analyze   # should report: No issues found
```

---

## Android permissions

The app requests the following at runtime where required:

| Permission | Purpose |
|------------|---------|
| `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` / `BLUETOOTH_ADVERTISE` | BLE discovery and messaging |
| `ACCESS_FINE_LOCATION` | Required by Android for BLE scanning |
| `ACCESS_WIFI_STATE` / `CHANGE_WIFI_STATE` | WiFi Direct P2P group management |
| `CAMERA` | QR code scanning |
| `RECORD_AUDIO` | Voice messages |

---

## Key dependencies

| Package | Use |
|---------|-----|
| `flutter_blue_plus` | BLE scanning and GATT communication |
| `provider` | State management |
| `shared_preferences` | Conversation and message persistence |
| `flutter_secure_storage` | Encryption key storage |
| `encrypt` + `pointycastle` | RSA-OAEP / AES-GCM encryption |
| `local_auth` | Biometric authentication |
| `qr_flutter` + `mobile_scanner` | QR code generation and scanning |
| `image_picker` + `flutter_image_compress` | Photo picking and compression |
| `record` + `audioplayers` | Voice message recording and playback |
| `dart_jsonwebtoken` | Age verification tokens |

---

## Roadmap

- [ ] Disappearing message enforcement (auto-delete timer in message storage)
- [ ] Group conversations over LAN
- [ ] Video calls over WiFi Direct
- [ ] iOS BLE support
- [ ] Mesh relay — extend range by forwarding through intermediate peers
- [ ] Reputation / trust scores (local, not server-based)

---

## License

GPL v3 — free for personal use. Commercial use requires a separate license with revenue sharing. See [LICENSE](LICENSE).
