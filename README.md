# Ahoy

> **Nothing Between** — privacy-first, peer-to-peer chat for people in the same space.

Ahoy is a Flutter/Android app that lets nearby devices discover each other and chat with no server, no internet, and no account registration beyond a local password. All communication happens on-device over one of three transports — WiFi Direct, local network (LAN), or Bluetooth LE — chosen automatically by signal strength and capability. Every message is end-to-end encrypted with a per-user RSA-2048 keypair stored in the Android Keystore. Nothing leaves the physical space.

---

## Table of Contents
[build](android/build)
1. [Architecture Overview](#1-architecture-overview)
2. [Project Structure](#2-project-structure)
3. [Cold Start — App Launch](#3-cold-start--app-launch)
4. [Auth Flow — First Launch (Sign Up)](#4-auth-flow--first-launch-sign-up)
5. [Auth Flow — Returning User (Sign In)](#5-auth-flow--returning-user-sign-in)
6. [Transport Startup](#6-transport-startup)
7. [Main Shell — Tab Navigation](#7-main-shell--tab-navigation)
8. [Discover Screen](#8-discover-screen)
9. [Conversations Screen](#9-conversations-screen)
10. [Chat Screen](#10-chat-screen)
11. [My Profile Screen](#11-my-profile-screen)
12. [Peer Profile Screen](#12-peer-profile-screen)
13. [Settings Screen](#13-settings-screen)
14. [Sign Out & App Close](#14-sign-out--app-close)
15. [Outbound Message Pipeline](#15-outbound-message-pipeline)
16. [Inbound Message Pipeline](#16-inbound-message-pipeline)
17. [WiFi Direct Transport](#17-wifi-direct-transport)
18. [LAN Transport](#18-lan-transport)
19. [BLE Transport](#19-ble-transport)
20. [Peer Discovery & Deduplication](#20-peer-discovery--deduplication)
21. [Encryption & Crypto Pipeline](#21-encryption--crypto-pipeline)
22. [Storage Layer](#22-storage-layer)
23. [Android Native Bridge](#23-android-native-bridge)
24. [Data Models Reference](#24-data-models-reference)
25. [Enums Reference](#25-enums-reference)
26. [Android Permissions](#26-android-permissions)
27. [Key Dependencies](#27-key-dependencies)
28. [Getting Started](#28-getting-started)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer (Dart)                      │
│  SignIn  SignUp  Discover  Chats  Chat  Profile  Settings   │
│               Widgets: PeerCard, MessageBubble, Badges      │
└───────────────────────────┬─────────────────────────────────┘
                            │  context.watch / context.read
┌───────────────────────────▼─────────────────────────────────┐
│                    Provider Layer (Dart)                    │
│  AuthProvider  ChatProvider  DiscoveryProvider              │
│  ProfileProvider  TransportProvider                         │
└──────┬────────────────┬───────────────────────┬─────────────┘
       │                │                       │
┌──────▼──────┐  ┌──────▼──────┐  ┌────────────▼────────────┐
│ AuthService │  │ ChatService │  │    DiscoveryService     │
│ ProfileSvc  │  │ MsgStore    │  │    TransportManager     │
│ CryptoSvc   │  │ ConvStore   │  │                         │
│ KeyStore    │  │ MediaSvc    │  │                         │
└──────┬──────┘  └─────────────┘  └────────────┬────────────┘
       │                                        │
┌──────▼────────────────────────────────────────▼─────────────┐
│                    Transport Layer (Dart)                   │
│   WiFiDirectTransport   LanTransport   BleTransport         │
└──────────────────────────────┬──────────────────────────────┘
                               │  MethodChannel
┌──────────────────────────────▼──────────────────────────────┐
│               Android Native (Kotlin — MainActivity.kt)     │
│   WiFi P2P Manager + TCP ServerSocket   BLE GATT Server     │
└─────────────────────────────────────────────────────────────┘
```

**Transport Priority (highest bandwidth wins):**
```
WiFi Direct  ──►  LAN  ──►  BLE
  ~250 Mbps      ~54 Mbps    ~1 Mbps
  media: yes     media: yes  media: no
```

**Storage split:**
```
SecureStore (Android Keystore / EncryptedSharedPreferences)
  └─ RSA private key, RSA public key, password hash, user ID, biometric flag

PrefsStore (SharedPreferences)
  └─ Profile JSON, conversations, messages, transport flags, blocked UUIDs
```

---

## 2. Project Structure

```
lib/
├── main.dart                         Entry point — runApp(AhoyApp())
└── Ahoy/
    ├── ahoy_app.dart                 App root: service init, MultiProvider wiring
    ├── core/
    │   ├── constants.dart            UUIDs, ports, key names, size limits
    │   ├── enums.dart                TransportMode, MessageType, MessageStatus, Gender, PeerStatus
    │   └── errors.dart               TransportError (thrown for BLE media attempts)
    ├── models/
    │   ├── local_user.dart           Signed-in user profile (stored locally)
    │   ├── peer_profile.dart         Peer's public profile (sent over-the-air)
    │   ├── nearby_peer.dart          In-memory discovered peer (multi-transport)
    │   ├── message.dart              Single chat message
    │   └── conversation.dart         Chat thread metadata (last message, unread count)
    ├── providers/
    │   ├── auth_provider.dart        Auth state machine: unknown → signedOut → signedIn
    │   ├── profile_provider.dart     Own profile load/edit/avatar
    │   ├── discovery_provider.dart   Peer list, transport toggles, block list
    │   ├── transport_provider.dart   Live transport mode per peer (for media gating)
    │   └── chat_provider.dart        Conversation list, message cache, inbound listener
    ├── router/
    │   └── ahoy_router.dart          Route name constants (Navigator.pushNamed paths)
    ├── screens/
    │   ├── root_screen.dart          Auth gate + transport bootstrap controller
    │   ├── main_shell.dart           4-tab NavigationBar scaffold
    │   ├── auth/
    │   │   ├── sign_in_screen.dart   Password + biometric sign-in
    │   │   └── sign_up_screen.dart   Account creation form
    │   ├── discover/
    │   │   └── discover_screen.dart  Nearby peer cards with pull-to-refresh
    │   ├── chat/
    │   │   ├── conversations_screen.dart  Conversation list with unread badges
    │   │   └── chat_screen.dart           Message thread + all send actions
    │   ├── profile/
    │   │   ├── my_profile_screen.dart     Own profile view + edit form
    │   │   └── peer_profile_screen.dart   Peer's public profile + block menu
    │   └── settings/
    │       └── settings_screen.dart       Transport toggles, privacy, sign-out
    ├── services/
    │   ├── transport_manager.dart    Multiplexes 3 transports; routing tables; alias resolution
    │   ├── auth/
    │   │   └── auth_service.dart     Signup/signin/biometric business logic
    │   ├── crypto/
    │   │   ├── crypto_service.dart   RSA-2048 keygen, AES-256-GCM encrypt, PBKDF2 hash
    │   │   └── key_store.dart        SecureStore ↔ CryptoService bridge
    │   ├── storage/
    │   │   ├── prefs_store.dart      SharedPreferences wrapper (JSON helpers)
    │   │   └── secure_store.dart     FlutterSecureStorage wrapper
    │   ├── profile/
    │   │   └── profile_service.dart  Profile CRUD, avatar file management
    │   ├── chat/
    │   │   ├── chat_service.dart     Inbound/outbound message logic + encryption
    │   │   ├── conversation_store.dart  Async-mutex conversation persistence
    │   │   └── message_store.dart    Per-conversation message list persistence
    │   ├── discovery/
    │   │   └── discovery_service.dart  Peer map, shortId→UUID index, stale cleanup
    │   ├── media/
    │   │   └── media_service.dart    Image pick/capture, voice record/play
    │   └── transport/
    │       ├── transport_interface.dart  TransportInterface, InboundPacket, PeerAnnouncement
    │       ├── wifi_direct_transport.dart  WiFi P2P via MethodChannel 'wifi_direct'
    │       ├── lan_transport.dart     UDP discovery + TCP messaging
    │       └── ble_transport.dart     BLE scan/advertise + GATT chunked write
    └── widgets/
        ├── common/
        │   ├── peer_avatar.dart       Avatar with file/base64/gender-icon fallback
        │   └── transport_badge.dart   Colored chip per TransportMode
        ├── auth/
        │   └── password_field.dart    Password input with visibility toggle + validator
        ├── chat/
        │   ├── message_bubble.dart    Rounded message bubble (text/image/voice + reply header)
        │   ├── message_input_bar.dart Text field + media buttons + send button
        │   └── reply_preview.dart     Reply-to bar with clear button
        └── discover/
            ├── peer_card.dart         Peer list tile with transport badges
            └── discovery_controls.dart  Transport toggle bottom sheet (referenced from Settings)

android/app/src/main/kotlin/com/example/ahoy/
└── MainActivity.kt   WiFi P2P manager, TCP ServerSocket, BLE GATT server, both MethodChannels
```

---

## 3. Cold Start — App Launch

```
main.dart
  └─ WidgetsFlutterBinding.ensureInitialized()
  └─ runApp(AhoyApp())

AhoyApp (StatefulWidget)
  └─ initState() → _init() [async]
       │
       ├─ 1.  SecureStore()                  — Android Keystore wrapper
       ├─ 2.  PrefsStore()                   — SharedPreferences (await .init())
       ├─ 3.  CryptoService()                — RSA/AES engine (inactive until keys loaded)
       ├─ 4.  KeyStore(secureStore, crypto)  — SecureStore ↔ CryptoService bridge
       ├─ 5.  AuthService(secureStore, prefs, crypto, keyStore)
       ├─ 6.  ProfileService(prefs)
       ├─ 7.  TransportManager()             — creates WiFiDirectTransport, LanTransport, BleTransport
       ├─ 8.  DiscoveryService()             — in-memory peer map + cleanup timer
       ├─ 9.  ConversationStore(prefs)
       ├─ 10. MessageStore(prefs)
       ├─ 11. ChatService(transport, convStore, msgStore, crypto)
       ├─ 12. MediaService()
       │
       └─ _ready = true → build()
            └─ MultiProvider [
                 Provider.value(secureStore, prefs, crypto, transportManager, profileService, mediaService),
                 ChangeNotifierProvider(AuthProvider),
                 ChangeNotifierProvider(ProfileProvider),
                 ChangeNotifierProvider(TransportProvider),
                 ChangeNotifierProvider(DiscoveryProvider),
                 ChangeNotifierProvider(ChatProvider),
               ]
            └─ home: RootScreen()
```

**RootScreen bootstrap:**
```
RootScreen.initState()
  └─ _bootstrap() [async]
       └─ AuthProvider.checkSession()
            └─ AuthService.isSignedIn   (checks SecureStore for keyPasswordHash)
            └─ if signed in: AuthState.signedIn
            └─ if not:       AuthState.signedOut

RootScreen.build()
  └─ if auth.isSignedIn && auth.user != null  →  MainShell
  └─ else                                     →  SignInScreen (with nav to SignUpScreen)

AuthProvider addListener → _maybeStartTransports()   [fires on every auth state change]
```

---

## 4. Auth Flow — First Launch (Sign Up)

**Screen:** `lib/Ahoy/screens/auth/sign_up_screen.dart`

**Form fields:**
| Field | Validation | Notes |
|-------|-----------|-------|
| Display Name | required, non-empty | shown to peers |
| Password | ≥ 8 characters | local-only, hashed with PBKDF2 |
| Bio | optional | max 200 chars |
| Gender | segmented: Male / Female / Other | optional |
| Interests | filter chips (multi-select) | Music, Tech, Sports, Food, Travel, Art, Gaming, Reading, Fitness, Nature |

**On submit → `AuthProvider.signUp(username, password, gender, interests?, bio?)`:**

```
AuthService.signUp()
  ├─ Validate: username non-empty, password ≥ 8 chars
  ├─ Generate UUID v4 (user ID)
  ├─ Generate shortId = CryptoService.shortIdFromUuid(uuid)
  │     SHA-256(uuid) → first 12 hex chars → BigInt → base-36 → pad/trim to 6 → uppercase
  ├─ Generate RSA-2048 keypair in Dart Isolate (non-blocking)
  │     PointyCastle: 2048-bit, exponent 65537, Miller-Rabin certainty 64
  │     DER-encode → PEM wrap
  ├─ KeyStore.save(privateKeyPEM, publicKeyPEM) → SecureStore
  ├─ KeyStore.load()  → CryptoService.activate()  (keys now in memory)
  ├─ Hash password: PBKDF2-HMAC-SHA256, 100 000 iterations, 16-byte random salt
  │     stored as "pbkdf2:{saltHex}:{derivedKeyHex}"
  ├─ SecureStore.write(keyUserId, uuid)
  ├─ SecureStore.write(keyPasswordHash, hash)
  └─ PrefsStore.setJson(prefProfile, LocalUser.toJson())

AuthProvider.state = AuthState.signedIn
AuthProvider notifyListeners()
  └─ RootScreen._maybeStartTransports()   [see §6]
```

---

## 5. Auth Flow — Returning User (Sign In)

**Screen:** `lib/Ahoy/screens/auth/sign_in_screen.dart`

**On init — biometric auto-attempt:**
```
SignInScreen.initState()
  └─ _tryBiometric()
       └─ AuthProvider.isBiometricAvailable  (checks platform + LocalAuthentication)
       └─ AuthProvider.isBiometricEnabled    (reads SecureStore keyBiometricEnabled)
       └─ if both true:
            AuthProvider.signInWithBiometric()
              └─ LocalAuthentication.authenticate()   (fingerprint / face)
              └─ if approved: KeyStore.load() → CryptoService.activate()
              └─ load LocalUser from PrefsStore
              └─ AuthState.signedIn
```

**Manual password sign-in:**
```
AuthProvider.signIn(password)
  └─ AuthService.signIn(password)
       ├─ Read stored hash from SecureStore
       ├─ CryptoService.verifyPassword(password, storedHash)
       │     if "pbkdf2:" prefix: re-derive with stored salt, constant-time compare
       │     else (legacy SHA-256): hash with stored salt, compare
       ├─ KeyStore.load() → CryptoService.activate()
       └─ Load LocalUser from PrefsStore
```

**Error handling:**
- `AuthProvider.error` holds the last error string
- `AuthProvider.clearError()` clears it
- SignInScreen shows an error banner when `auth.error != null`

---

## 6. Transport Startup

Triggered once after `AuthState.signedIn` via `RootScreen._maybeStartTransports()`.

```
_maybeStartTransports()   [guarded — runs exactly once per session]
  │
  ├─ Request Android runtime permissions:
  │    ACCESS_FINE_LOCATION, BLUETOOTH_SCAN, BLUETOOTH_CONNECT,
  │    BLUETOOTH_ADVERTISE, NEARBY_WIFI_DEVICES
  │
  ├─ TransportManager.start(
  │     uuid, shortId, displayName, statusMessage?, publicKeyPEM?,
  │     bleEnabled, lanEnabled, wifiDirectEnabled   ← from DiscoveryProvider prefs
  │   )
  │     ├─ Subscribe to each transport's packetStream → TransportManager._onPacket()
  │     ├─ Subscribe to each transport's announcementStream → record transport + forward
  │     ├─ startAdvertising() on all enabled transports   [identity broadcast]
  │     └─ startScanning() on all enabled transports      [peer discovery]
  │
  ├─ Subscribe to TransportManager.announcementStream
  │     → DiscoveryProvider.onAnnouncement()   [peer list updates]
  │
  └─ ChatProvider.init(myUuid, receiveOff, blockedUuids)
       └─ Load conversations from ConversationStore
       └─ Subscribe to TransportManager.packetStream   [inbound messages]
```

---

## 7. Main Shell — Tab Navigation

**File:** `lib/Ahoy/screens/main_shell.dart`

Uses `IndexedStack` so all tabs stay mounted; only the active one is visible.

```
NavigationBar destinations:
  0 — radar icon       →  DiscoverScreen
  1 — chat icon        →  ConversationsScreen   (Badge with unread count when > 0)
  2 — person icon      →  MyProfileScreen
  3 — settings icon    →  SettingsScreen
```

The unread badge is driven by `ChatProvider.totalUnreadCount`:
```dart
int get totalUnreadCount =>
    _conversations.fold(0, (sum, conv) => sum + conv.unreadCount);
```
Shows a red `Badge` widget with count. Displays nothing when count is zero.

---

## 8. Discover Screen

**File:** `lib/Ahoy/screens/discover/discover_screen.dart`

### 8a. How Peers Appear

**LAN** (`lib/Ahoy/services/transport/lan_transport.dart`):
```
Every 5 seconds:
  _broadcast()
    → UDP packet to 255.255.255.255:45678 AND each interface's X.Y.Z.255:45678
    → JSON: { type, uuid, shortId, displayName, statusMessage, publicKeyPEM, port }

On receive (_onUdpDatagram):
  → Parse JSON, ignore self (uuid == _myUuid)
  → _peerConns[uuid] = _PeerConn(senderIP, port)
  → Emit PeerAnnouncement (uuid, shortId, displayName, publicKeyPEM, transport: lan)
```

**BLE** (`lib/Ahoy/services/transport/ble_transport.dart`):
```
Scan result arrives (_onScanResult):
  → Cache device: _scannedDevices[remoteId] = device
  → _parseAnnouncement():
       serviceData[bleServiceUuid] → bytes
       bytes = shortId[0:6] + 0x00 + displayName[0:6]   (max 13 bytes)
       Skip if shortId matches own shortId (self-filter)
       Emit PeerAnnouncement (uuid: BT_MAC, shortId, displayName, transport: ble)
       [real Ahoy UUID unknown until first message exchange]
```

**WiFi Direct** (`lib/Ahoy/services/transport/wifi_direct_transport.dart`):
```
Every 30 seconds (+ on startup):
  _runDiscoverPeers()
    → MethodChannel 'wifi_direct' invokeMethod 'discoverPeers'
    → [Kotlin: WifiP2pManager.discoverPeers()]
    → [Android broadcast: WIFI_P2P_PEERS_CHANGED → requestPeers()]
    → Dart callback: onPeersDiscovered(List<{deviceName, deviceAddress, status}>)
    → _handlePeersDiscovered():
         For each peer not already in _addressToUuid and not in _connectingAddresses:
           _connectingAddresses.add(address)
           _tryConnect(address)   [auto-connect, no stub announcement emitted]

After TCP connection & identity exchange:
  → address removed from _connectingAddresses
  → Emit PeerAnnouncement with real Ahoy UUID (see §17)
```

**All announcements flow:**
```
PeerAnnouncement
  → TransportManager._recordTransport(uuid, mode)
  → TransportManager.announcementStream
  → DiscoveryProvider.onAnnouncement()
  → DiscoveryService.onAnnouncement()   [dedup/merge — see §20]
  → DiscoveryService.peerStream
  → DiscoveryProvider._peers updated
  → notifyListeners()
  → DiscoverScreen rebuilds
```

### 8b. Peer Card

Each `NearbyPeer` renders as a `PeerCard`:
- **Avatar**: `PeerAvatar` — file path → base64 → gender-colored icon (fallback chain)
- **Title**: `peer.displayName`
- **Subtitle**: status message (if any) + `TransportBadges` (colored chips: green=WiFi Direct, blue=LAN, indigo=BLE)
- **Trailing**: "Chat" button, or block icon if `peer.isBlocked`

**Chat button** → `_openChat(context, peer)`:
```
_openChat()
  → MessageStore.conversationId(myUuid, peer.uuid)   [deterministic SHA-256 hash]
  → Find existing Conversation in ChatProvider, or construct a new one
  → Navigator.push(ChatScreen(conversation, peer))
```

**Tap card** → `Navigator.push(PeerProfileScreen(peer))`

### 8c. Pull-to-Refresh

`RefreshIndicator` wraps both the peer list and the empty state (`SingleChildScrollView` with `AlwaysScrollableScrollPhysics` so gesture works even with no content).

```
onRefresh → DiscoveryProvider.refreshPeers()
  → Snapshot: ble, lan, wd current flags
  → setBleEnabled(false) → setBleEnabled(ble)        [uses provider setters — prefs + transport stay in sync]
  → setLanEnabled(false) → setLanEnabled(lan)
  → setWifiDirectEnabled(false) → setWifiDirectEnabled(wd)
```

### 8d. Banners

Two conditional banners above the peer list:
- **Off the Grid** (grey) — appears when `discovery.offGrid` is true; user is not broadcasting and invisible to others
- **Receive Off** (orange) — appears when `discovery.receiveOff` is true; new inbound chat requests are silently dropped

---

## 9. Conversations Screen

**File:** `lib/Ahoy/screens/chat/conversations_screen.dart`

Reads `ChatProvider.conversations` (sorted newest-first by `lastMessageAt`).

Each `_ConversationTile` shows:
- **Avatar**: blue circle (normal) or red circle with block icon (blocked)
- **Unread badge**: red overlay on avatar, count capped at "9+"
- **Title**: peer display name — **bold** if `unreadCount > 0`
- **Transport chip**: `TransportBadge(conv.lastTransport)`
- **Subtitle**: `lastMessagePreview` — or `[Blocked]` if `isBlocked`
- **Trailing date**: `HH:MM` if today, `DD/MM` otherwise

**Tap** → reconstruct `NearbyPeer` from conversation metadata → `Navigator.push(ChatScreen(...))`

**Empty state**: centered "No conversations yet" text.

---

## 10. Chat Screen

**File:** `lib/Ahoy/screens/chat/chat_screen.dart`

### 10a. On Enter
```
initState()
  → ChatProvider.markRead(convId)   [zeros unreadCount, persists to ConversationStore]
  → Scroll controller animates to end of message list
  → Watch ChatProvider, TransportProvider, DiscoveryProvider
```

### 10b. Send Text
```
MessageInputBar:
  - TextField (1–4 lines, Enter = newline, not send)
  - Send button enabled only when text.trim().isNotEmpty

On send:
  → ChatProvider.sendMessage(type: MessageType.text, content: text)
  → Appended to _messages cache
  → Conversation reloaded
  → notifyListeners()
  → ListView scrolls to bottom
```

### 10c. Reply to a Message
```
Long-press any MessageBubble → onReply callback
  → _replyTo = message   (setState)
  → ReplyPreview bar appears above input (first 80 chars of content)

On send:
  → replyToId = _replyTo.id
  → replyToPreview = _replyTo.content (first 80 chars)
  → Both fields included in outgoing payload
  → MessageBubble renders reply header for recipient

Clear reply:
  → ReplyPreview close button → _replyTo = null
```

### 10d. Send Image
```
Gallery button → MediaService.pickImage()
  → image_picker opens system gallery
  → Returns local file path

Camera button → MediaService.capturePhoto()
  → image_picker opens camera
  → Returns local file path

Both → ChatProvider.sendMessage(type: MessageType.image, content: filePath)
  → ChatService._encodeMediaContent(filePath)
       → File.readAsBytesSync() → base64.encode()
  → Transmitted as base64 string in payload
  → Receiver: base64.decode() → write to ahoy_media_{msgId}.jpg
```

### 10e. Voice Message
```
Mic button (held):
  → MediaService.startRecording()   (record package)
  → Input bar shows red stop icon, isRecording = true

Stop button:
  → MediaService.stopRecording() → AAC file path
  → ChatProvider.sendMessage(type: MessageType.voice, content: filePath)
  → Transmitted as base64, saved as ahoy_media_{msgId}.aac on receive

Tap voice bubble:
  → MessageBubble.onPlayAudio callback
  → MediaService.playAudio(message.content)   (audioplayers package)
```

### 10f. BLE Restriction
When `TransportProvider.canSendMedia(peerUuid)` returns `false` (peer reachable only via BLE):
- Gallery, camera, mic buttons are **hidden**
- TextField hint text changes to **"Text only (BLE mode)"**
- Attempting to tap hidden buttons (if shown) shows a SnackBar explanation

### 10g. Block / Unblock
```
AppBar menu → "Block"
  → ChatProvider.blockConversation(convId)
       → ConversationStore.setBlocked(convId, true)
  → DiscoveryProvider.blockPeer(peerUuid)
       → DiscoveryService.updateBlockedStatus(peerUuid, true)
       → blockedUuids.add(peerUuid) → _saveBlockedUuids() → PrefsStore
  → Overlay banner: "This conversation is blocked"
  → Inbound packets from this peer silently dropped in ChatService.onInboundPacket()

AppBar menu → "Unblock"
  → Reverses both operations
```

### 10h. Delete Conversation
```
AppBar menu → "Delete"
  → Confirmation AlertDialog
  → Confirm:
       ChatProvider.deleteConversation(convId)
         → ConversationStore.softDelete(convId)   [isDeleted = true, not physically removed]
         → MessageStore.deleteConversationMessages(convId)   [prefs key removed]
         → _messages.remove(convId)   [cache cleared]
         → Conversations reloaded
  → Navigator.pop() [back to Conversations screen]
```

### 10i. Header Transport Badges
The AppBar subtitle shows `TransportBadges` sourced from `DiscoveryProvider.peers`:
```
peers.firstWhere((p) => p.uuid == peer.uuid)?.transports
```
Updates live as transports connect/disconnect.

### 10j. Error Banner
When `ChatProvider.error != null` (e.g., "Peer is not reachable on any transport"):
- A `MaterialBanner` appears at the top with the error message
- Dismiss action calls `ChatProvider.clearError()`

---

## 11. My Profile Screen

**File:** `lib/Ahoy/screens/profile/my_profile_screen.dart`

### 11a. View
- `PeerAvatar` with avatar file path → circular display
- Display name (headline style)
- `@shortId` (deterministic 6-char code)
- Status message (italic, quoted)
- Bio (center-aligned)
- Interests as `FilterChip` widgets (read-only)
- **Sign Out** button (navigates to Settings or triggers sign-out)
- **Edit** button → pushes `_EditProfileScreen`

### 11b. Edit
```
_EditProfileScreen fields:
  - Display Name (TextFormField, required)
  - Bio (max 200 chars, optional)
  - Status Message (max 80 chars, optional)
  - Gender (SegmentedButton: Male / Female / Other)
  - Interests (FilterChip multi-select, same 10 options as sign-up)

Save:
  → ProfileProvider.update(username?, bio?, gender?, interests?, statusMessage?)
       → ProfileService.updateProfile(current, ...)
            → Build new LocalUser with changed fields
            → PrefsStore.setJson(prefProfile, user.toJson())
       → profileProvider.setUser(newUser)
  → AuthProvider.updateUser(newUser)   [syncs display name for outgoing messages]
  → TransportManager.startAdvertising(...)   [re-broadcasts updated identity to peers]
  → Navigator.pop()
```

### 11c. Avatar Update
```
Camera icon overlay tap:
  → ProfileProvider.updateAvatar(user)
       → MediaService.pickImage() OR camera capture
       → Resize/save to app documents dir: avatar_{userId}.jpg
       → Update LocalUser.avatarPath
       → Persist to PrefsStore
       → notifyListeners()
```

---

## 12. Peer Profile Screen

**File:** `lib/Ahoy/screens/profile/peer_profile_screen.dart`

Read-only view of a `NearbyPeer`:
- `PeerAvatar` (gender: unspecified icon, no actual avatar data available)
- Display name + `@shortId`
- `TransportBadges` for all transports seen for this peer
- Status message (if set)
- Blocked banner ("You have blocked this person") if `peer.isBlocked`

**Menu actions:**
```
Block:
  → DiscoveryProvider.blockPeer(peer.uuid)
       → blockedUuids.add(uuid)
       → DiscoveryService.updateBlockedStatus(uuid, true)
       → _saveBlockedUuids() → PrefsStore.setString(prefBlockedUuids, json)

Unblock:
  → DiscoveryProvider.unblockPeer(peer.uuid)   [reverse]
```

---

## 13. Settings Screen

**File:** `lib/Ahoy/screens/settings/settings_screen.dart`

| Setting | Type | Storage Key | Code Path |
|---------|------|-------------|-----------|
| WiFi Direct | Toggle | `prefWifiDirectEnabled` | `DiscoveryProvider.setWifiDirectEnabled(v)` → `TransportManager.setWifiDirectEnabled(v)` → start/stop WD transport |
| Local Network | Toggle | `prefLanEnabled` | `DiscoveryProvider.setLanEnabled(v)` → `TransportManager.setLanEnabled(v)` → start/stop LAN transport |
| Bluetooth | Toggle | `prefBleEnabled` | `DiscoveryProvider.setBleEnabled(v)` → `TransportManager.setBleEnabled(v)` → start/stop BLE transport |
| Off the Grid | Toggle | `prefOffGrid` | `DiscoveryProvider.setOffGrid(v)` → if true: `TransportManager.stopAdvertising()` |
| Receive Off | Toggle | `prefReceiveOff` | `DiscoveryProvider.setReceiveOff(v)` → flag read by `ChatService.onInboundPacket()` |
| Biometric Sign-In | Toggle (conditional) | `keyBiometricEnabled` | `AuthProvider.enableBiometric()` → `SecureStore.write('true')` — shown only if `isBiometricAvailable` |
| Sign Out & Erase | Button | — | See §14 |

---

## 14. Sign Out & App Close

### Sign Out
```
AuthProvider.signOut()
  └─ AuthService.signOut(onTransportStop: () => TransportManager.stopAll())
       ├─ TransportManager.stopAll()
       │     → stopAdvertising() on all transports
       │     → stopScanning() on all transports
       │     → cancel all stream subscriptions
       │     → clear _peerTransports, _peerAliases
       ├─ KeyStore.clear()
       │     → SecureStore.delete(keyPrivateKey)
       │     → SecureStore.delete(keyPublicKey)
       │     → CryptoService.deactivate()   [_privateKey = null, isReady = false]
       ├─ PrefsStore.clearAll()             [profile, conversations, messages, all flags]
       └─ SecureStore.clearAll()            [userId, passwordHash, biometricEnabled]

ProfileProvider.clear()   [nulls in-memory user]
AuthProvider.state = AuthState.signedOut
  → RootScreen rebuilds → SignInScreen
```

### App Destroy
```
AhoyApp.dispose()
  → TransportManager.dispose()
       → stopAll() + close stream controllers + dispose each transport
  → MediaService.dispose()
       → Stop any active recording, release audio player
```

---

## 15. Outbound Message Pipeline

Full call chain for sending one message:

```
UI: Send button pressed
  │
  ▼
ChatProvider.sendMessage(myUuid, myShortId, myDisplayName,
                         peerUuid, peerDisplayName, peerShortId,
                         type, content, myPublicKeyPEM?, peerPublicKeyPEM?,
                         replyToId?, replyToPreview?)
  │
  ▼
ChatService.sendMessage()
  ├─ TransportManager.currentModeFor(peerUuid)   [check reachability]
  │    If type == image/voice AND mode == BLE → throw TransportError
  │    If mode == none → throw TransportError
  │
  ├─ convId = CryptoService.conversationId(myUuid, peerUuid)
  │    SHA-256(sort([myUuid, peerUuid]).join(':'))[0:32]
  │
  ├─ msgId = UUID.v4()
  │
  ├─ _buildPayload():
  │    ├─ For text:  wireContent = content
  │    ├─ For media: wireContent = base64(File(content).readAsBytesSync())
  │    └─ If peerPublicKeyPEM != null && crypto.isReady:
  │         wireContent = CryptoService.encryptForPeer(wireContent, peerPublicKeyPEM)
  │         encrypted = true
  │         [falls back to plaintext on exception, logs error]
  │    → Returns Map: { msgType, msgId, convId, type, content, isEncrypted,
  │                     senderPublicKeyPEM, replyToId, replyToPreview, timestamp }
  │
  ├─ Message(status: sending) created
  │
  ├─ MessageStore.addMessage(message)
  │    → loadMessages(convId) → dedup check → append → PrefsStore.setJsonList()
  │
  ├─ _updateConversationOnSend()
  │    → ConversationStore.upsert() [async mutex]
  │         → load → find/create → update lastMessageAt/Preview/Transport → persist
  │
  ├─ TransportManager.send(peerUuid, myUuid, myShortId, myDisplayName, payload)
  │    ├─ canonical = _peerAliases[peerUuid] ?? peerUuid
  │    ├─ jsonPayload = jsonEncode({...payload, from, fromShortId, fromName})
  │    ├─ mode = currentModeFor(canonical)
  │    └─ Switch mode:
  │         ├─ wifiDirect → WiFiDirectTransport.send(canonical, jsonPayload)
  │         │    address = _uuidToAddress[canonical] ?? _groupOwnerAddress
  │         │    MethodChannel('wifi_direct').invokeMethod('sendData', {data, recipientIP?})
  │         │    [Kotlin: Socket(ip, 8765) → DataOutputStream.writeInt(len) + write(data)]
  │         │
  │         ├─ lan → LanTransport.send(canonical, jsonPayload)
  │         │    conn = _peerConns[canonical]
  │         │    Socket.connect(conn.address, 45679)
  │         │    socket.write(jsonPayload + '\n') → flush() → close()
  │         │
  │         └─ ble → BleTransport.send(canonical, jsonPayload)
  │              device = _getOrConnect(canonical)
  │              services = device.discoverServices()
  │              characteristic = services[bleServiceUuid].char[bleCharUuid]
  │              _sendChunked(char, jsonPayload):
  │                totalChunks = ceil(bytes.length / 180)
  │                for seq in 0..totalChunks-1:
  │                  envelope = { m: msgId_ts, seq, total, data: base64(chunk) }
  │                  char.write(utf8(jsonEncode(envelope)), withoutResponse: false)
  │                  await 20ms
  │
  └─ MessageStore.updateMessageStatus(convId, msgId, sent | failed)

ChatProvider:
  → _messages cache updated
  → _conversations reloaded from ConversationStore
  → notifyListeners()
  → UI: message bubble appears with ✓ (sent) or ✗ (failed)
```

---

## 16. Inbound Message Pipeline

Full call chain from bytes arriving to message appearing in UI:

```
[WiFi Direct]
  Kotlin: handleIncomingConnection(socket)
    → soTimeout = 10s
    → DataInputStream.readInt() → length
    → readFully(data, 0, length)
    → runOnUiThread: methodChannel.invokeMethod('onDataReceived', {data, senderIP})
  Dart: WiFiDirectTransport._onKotlinCall('onDataReceived')
    → _handleDataReceived(raw):
         bytes = raw['data'], senderIP = raw['senderIP']
         json = jsonDecode(utf8.decode(bytes))
         if json['type'] == 'wdIdentity' → identity exchange (see §17)
         else:
           fromUuid = json['from']
           if _uuidToAddress missing fromUuid: learn route from senderIP
           emit InboundPacket(peerUuid: fromUuid, payload: utf8.decode(bytes))

[LAN]
  _onTcpConnection(socket):
    StringBuffer accumulates bytes
    Split on '\n', process each complete line
    onDone: process remaining buffer (no trailing newline)
    _processMessage(raw):
      json = jsonDecode(raw)
      emit InboundPacket(peerUuid: json['from'], payload: raw)

[BLE]
  Kotlin: onCharacteristicWriteRequest(device, value)
    → bleChannel.invokeMethod('onBleChunkReceived', {chunk, deviceAddress})
  Dart: BleTransport._onBleMethodCall('onBleChunkReceived')
    → _receiveChunk(chunk, deviceAddress):
         json = { m, seq, total, data }
         _chunkBuffer[m][seq] = data
         if count == total:
           sort by seq, concat base64.decode(chunk) for each
           payload = utf8.decode(allBytes)
           peerUuid = json['from'] from payload (or deviceAddress as fallback)
           emit InboundPacket(peerUuid, payload)
         [stale cleanup: 60s timeout per msgId, checked every 30s]

─────────────────────────────────────────────────────────────────

TransportManager._onPacket(packet)
  → canonical = _peerAliases[packet.peerUuid] ?? packet.peerUuid
  → _recordTransport(canonical, packet.transport)
  → emit InboundPacket(peerUuid: canonical, ...) to packetStream

─────────────────────────────────────────────────────────────────

ChatProvider._inboundSub.listen(packet)
  → ChatService.onInboundPacket(rawPayload, peerUuid, myUuid, transport, receiveOff, blockedUuids)
       ├─ json = jsonDecode(rawPayload)
       ├─ if json['msgType'] != 'chat': return null
       ├─ if peerUuid in blockedUuids: return null
       ├─ convId = conversationId(myUuid, peerUuid)
       ├─ if new conversation AND receiveOff: return null
       ├─ type = MessageType.values.byName(json['type'])
       ├─ if json['isEncrypted'] && crypto.isReady:
       │    content = CryptoService.decryptFromPeer(json['content'])
       │      → decode base64 envelope → parse {v, ek, iv, ct}
       │      → RSA-OAEP decrypt ek → aesKey
       │      → AES-256-GCM decrypt ct with aesKey + iv
       │      → return plaintext
       │    [on failure: log + return null — message dropped]
       ├─ if type == image/voice:
       │    content = _saveMediaToFile(content, msgId, type)
       │      → base64.decode → write to app docs/ahoy_media_{msgId}.{ext}
       │      → return file path
       ├─ MessageStore.addMessage(message)   [dedup by msgId]
       └─ _updateConversationOnReceive()
            → ConversationStore.upsert() [async mutex]
                 → unreadCount++
                 → update lastMessageAt, lastMessagePreview, peerPublicKeyPEM

  → if message != null:
       _messages.remove(convId)         [invalidate cache]
       _conversations = convStore.loadAll()
       notifyListeners()

UI:
  → ChatScreen (if open): new bubble appears at bottom
  → ConversationsScreen: conversation moves to top, unread count increments
  → MainShell: Chats tab badge updates
```

---

## 17. WiFi Direct Transport

**File:** `lib/Ahoy/services/transport/wifi_direct_transport.dart`  
**Native:** `android/app/src/main/kotlin/com/example/ahoy/MainActivity.kt`  
**MethodChannel:** `"wifi_direct"`

### Connection Lifecycle
```
1. Dart calls discoverPeers() every 30s
2. Kotlin: WifiP2pManager.discoverPeers() → system broadcast
3. System: WIFI_P2P_PEERS_CHANGED → requestPeers() → onPeersDiscovered(list)
4. Dart: auto-connect to each unknown peer
5. Kotlin: WifiP2pManager.connect(config)
6. System: WIFI_P2P_CONNECTION_CHANGED → requestConnectionInfo() → onConnectionInfoAvailable(info)
7. Kotlin: invoke onConnectionEstablished({ isGroupOwner, address })
8. Dart: store role + groupOwnerAddress → identity exchange
```

### Group Owner vs Client
```
One device becomes Group Owner (GO); all others are clients.

GO:
  - groupOwnerAddress = null  (it IS the owner)
  - connectedClients = thread-safe Set of client IPs (from TCP connections)
  - Sends data to all connectedClients (NULL recipientIP → broadcast in Kotlin)

Client:
  - groupOwnerAddress = GO's IP
  - Always sends data to groupOwnerAddress
```

### Identity Exchange Protocol
```
wdIdentity packet format:
{
  "type": "wdIdentity",
  "uuid": "real-ahoy-uuid",
  "shortId": "ABCDEF",
  "displayName": "Alice",
  "statusMessage": "optional"
}

Sequence:
  1. Client receives onConnectionEstablished
  2. Client sends wdIdentity to GO's IP
  3. GO receives via TCP → handleIncomingConnection → onDataReceived
  4. GO: _addressToUuid[senderIP] = clientUuid, _uuidToAddress[clientUuid] = senderIP
  5. GO: emit PeerAnnouncement with clientUuid
  6. GO: _sendIdentityTo(senderIP) → sends own wdIdentity to client
  7. Client receives → _addressToUuid[goIP] = goUuid, _uuidToAddress[goUuid] = goIP
  8. Client: emit PeerAnnouncement with goUuid
  9. Both sides now have routing tables; chat messages flow normally
```

### TCP Wire Protocol (Kotlin)
```
Send (cmdSendData):
  Socket(recipientIP, 8765)
  DataOutputStream.writeInt(data.size)   ← 4-byte big-endian length
  DataOutputStream.write(data)
  flush()

Receive (handleIncomingConnection) per connection:
  socket.soTimeout = 10_000              ← prevents thread blocking forever
  DataInputStream.readInt()              ← 4 bytes → length
  validate: 0 < length ≤ 10 MB
  DataInputStream.readFully(data)        ← exact `length` bytes
  socket.close()
  runOnUiThread: invokeMethod('onDataReceived', {data, senderIP})
```

---

## 18. LAN Transport

**File:** `lib/Ahoy/services/transport/lan_transport.dart`

### Discovery (UDP)
```
Port: 45678
Frequency: every 5 seconds
Targets: 255.255.255.255 + each interface's X.Y.Z.255

Announcement JSON:
{
  "type": "ahoy_announce",
  "uuid": "ahoy-uuid",
  "shortId": "ABCDEF",
  "displayName": "Alice",
  "statusMessage": "optional",
  "publicKeyPEM": "-----BEGIN RSA PUBLIC KEY-----...",
  "port": 45679
}

Peer expiry: 30 seconds after last announcement (isStale check)
_peerConns cache: uuid → (InternetAddress, port); removed on send failure
```

### Messaging (TCP)
```
Server port: 45679 (ServerSocket.bind)
Protocol: newline-delimited JSON ('\n' terminates each message)

Send:
  Socket.connect(peer.address, 45679, timeout: 5s)
  socket.write(jsonPayload + '\n')
  socket.flush()
  socket.close()

Receive (_onTcpConnection):
  StringBuffer accumulates arriving bytes
  Split on '\n' → process each complete line via _processMessage()
  onDone: process any remaining buffer content (messages without trailing newline)
  onError: socket.destroy()
```

---

## 19. BLE Transport

**File:** `lib/Ahoy/services/transport/ble_transport.dart`  
**Native GATT server:** `MainActivity.kt`  
**MethodChannel:** `"ble_advertiser"`

### UUIDs
```
Service:        12345678-1234-1234-1234-123456789abc
Characteristic: 12345678-1234-1234-1234-123456789def
Properties: READ | WRITE
Permissions: READ | WRITE
```

### Advertising (Peripheral)
```
Scan response payload (max 13 bytes):
  shortId[0:6]      (6 bytes — ASCII)
  0x00              (1 byte — separator)
  displayName[0:6]  (up to 6 bytes — ASCII)

Serves as initial identity broadcast; Ahoy UUID unknown until first GATT write
```

### Scanning & Backoff
```
Scan restart backoff (Android: max 5 scans / 30s):
  Initial: 8s
  On failure: backoff = min(backoff * 2, 120s)
  On success: backoff reset to 8s

_scanStateSub watches FlutterBluePlus.isScanning:
  When scan stops AND last start succeeded → schedule restart at current backoff
  When last start failed → catch block already scheduled restart (no duplicate)
```

### Chunked Messaging
```
Chunk envelope (JSON, per 180-byte chunk):
{
  "m":     "1234567890",    ← msgId (timestamp string)
  "seq":   0,               ← 0-indexed sequence number
  "total": 3,               ← total chunk count
  "data":  "base64..."      ← base64-encoded chunk bytes
}

Send:
  totalChunks = ceil(payload.length / 180)
  For each chunk:
    characteristic.write(utf8(envelope), withoutResponse: false)
    await Future.delayed(20ms)   ← prevents receiver overrun

Receive:
  _chunkBuffer[msgId][seq] = base64_data
  When count(_chunkBuffer[msgId]) == total:
    Sort by seq → concat base64.decode(chunk) → utf8.decode → full payload
    Emit InboundPacket

Stale chunk cleanup:
  Timer.periodic(30s): evict any msgId not updated in 60s
```

### Handler Registration
```
The Kotlin→Dart GATT write handler must be registered BEFORE any writes can arrive.
GATT server opens in startAdvertising() → handler registered there.
startScanning() also registers it to cover any ordering variation.
(setMethodCallHandler is idempotent — safe to call twice)
```

---

## 20. Peer Discovery & Deduplication

**File:** `lib/Ahoy/services/discovery/discovery_service.dart`

The key challenge: BLE and WiFi Direct initially identify peers by MAC address, not by Ahoy UUID. The discovery service merges these into a single canonical entry.

### Announcement Processing
```
onAnnouncement(announcement, blockedUuids) → PeerAlias?

Step 1: shortId lookup
  if announcement.shortId is non-empty:
    known = _shortIdToUuid[shortId]
    if known != null && known != announcement.uuid:
      → PeerAlias(tempId: announcement.uuid, canonicalId: known)
         (MAC address being resolved to known real UUID)
      canonicalUuid = known

Step 2: real UUID registration
  if announcement.uuid matches v4 UUID regex AND step 1 found nothing:
    _shortIdToUuid[shortId] = announcement.uuid
    scan _peers for any entry with same shortId but different key (temp entry):
      → PeerAlias(tempId: oldKey, canonicalId: announcement.uuid)
      → merge transports from temp entry
      → _peers.remove(oldKey)
      → emit and return

Step 3: normal upsert
  existing = _peers[canonicalUuid]
  bestTransport = lower index wins: [wifiDirect=0, lan=1, ble=2, none=3]
  allTransports = existing.transports ∪ {announcement.transport}
  _peers[canonicalUuid] = NearbyPeer(
    uuid: canonicalUuid,
    shortId: announcement.shortId if non-empty, else keep existing
    displayName: announcement.displayName if non-empty, else keep existing
    transport: bestTransport
    transports: allTransports
    lastSeen: now()
    isBlocked: blockedUuids.contains(canonicalUuid)
    statusMessage: announcement.statusMessage ?? existing
    publicKeyPEM: announcement.publicKeyPEM ?? existing
  )
  emit peerStream
```

### Alias Registration in TransportManager
When `DiscoveryService.onAnnouncement()` returns a `PeerAlias`:
```
DiscoveryProvider.onAnnouncement():
  → TransportManager.registerAlias(tempId: MAC, canonicalId: ahoyUuid)
       → _peerAliases[tempId] = canonicalId
       → merge _peerTransports[tempId] → _peerTransports[canonicalId]
       → Future packets from the MAC routed as the canonical UUID
```

### Stale Peer Cleanup
```
startCleanupTimer():
  Timer.periodic(10s):
    staleKeys = _peers where (now() - lastSeen) > 30s
    for each staleKey:
      _peers.remove(staleKey)
      _shortIdToUuid.remove(peer.shortId)   ← allows re-registration with new UUID
    onRemoved(staleKeys) callback:
      → TransportManager.removePeer(uuid) for each
           → _peerTransports.remove(uuid)
           → _peerAliases.removeWhere((_, v) => v == uuid)
    emit peerStream
```

---

## 21. Encryption & Crypto Pipeline

**File:** `lib/Ahoy/services/crypto/crypto_service.dart`

### RSA Key Generation
```
generateKeyPair()  [runs in Dart Isolate]
  → PointyCastle RSAKeyGenerator
       keySize: 2048 bits
       publicExponent: 65537
       certainty: 64  (Miller-Rabin primality test iterations)
  → DER-encode modulus, exponents, CRT params
  → Wrap in PEM headers:
       "-----BEGIN RSA PUBLIC KEY-----"
       "-----BEGIN RSA PRIVATE KEY-----"
  → Stored in SecureStore via KeyStore.save()
```

### Password Hashing
```
New format (PBKDF2-HMAC-SHA256):
  salt = Random.secure() → 16 bytes
  dk   = PBKDF2(password, salt, 100_000 iterations, 32 output bytes)
  stored: "pbkdf2:{saltHex}:{dkHex}"

Legacy format (SHA-256 + salt) — supported for verification only:
  stored: "{saltHex}:{sha256Hex}"

verifyPassword(password, storedHash):
  if starts with "pbkdf2:": re-derive with extracted salt → constant-time compare
  else: hash with extracted salt → compare
```

### Message Encryption (Hybrid AES-256-GCM + RSA-OAEP)
```
encryptForPeer(plaintext, peerPublicKeyPEM):
  1. Generate random 32-byte AES key
  2. Generate random 12-byte IV (GCM nonce)
  3. AES-256-GCM encrypt plaintext → ciphertext (includes 16-byte auth tag)
  4. RSA-OAEP (SHA-256) encrypt AES key with peer's public key
  5. Envelope:
       { "v": 2, "ek": base64(rsaEncryptedKey), "iv": base64(iv), "ct": base64(ciphertext) }
  6. Return: base64(utf8(jsonEncode(envelope)))

decryptFromPeer(encryptedBase64):
  1. base64.decode → utf8.decode → jsonDecode → envelope
  2. Check v == 2
  3. RSA-OAEP decrypt ek with own private key → aesKey (32 bytes)
  4. AES-256-GCM decrypt ct with aesKey + iv → plaintext (auth tag validated)
```

### Conversation & Short ID Derivation
```
conversationId(myUuid, peerUuid):
  sorted = [myUuid, peerUuid]..sort()
  return sha256("${sorted[0]}:${sorted[1]}").substring(0, 32)
  → Same ID regardless of who initiates the conversation

shortIdFromUuid(uuid):
  return sha256(uuid)[0:12_hex_chars] → BigInt → .toRadixString(36) → pad → [0:6] → uppercase
  → Deterministic 6-char alphanumeric code shown as @ABCDEF
```

---

## 22. Storage Layer

### SecureStore (`lib/Ahoy/services/storage/secure_store.dart`)
Backend: `flutter_secure_storage` → Android EncryptedSharedPreferences backed by Android Keystore. Keys are never exposed in plaintext outside the secure enclave.

| Key constant | Value stored |
|---|---|
| `keyUserId` | User's UUID |
| `keyPasswordHash` | `"pbkdf2:{saltHex}:{dkHex}"` |
| `keyPrivateKey` | RSA-2048 private key PEM |
| `keyPublicKey` | RSA-2048 public key PEM |
| `keyBiometricEnabled` | `"true"` or key absent |

Completely cleared on sign-out via `SecureStore.clearAll()`.

### PrefsStore (`lib/Ahoy/services/storage/prefs_store.dart`)
Backend: `shared_preferences` → Android SharedPreferences.

| Key constant | Value stored |
|---|---|
| `prefProfile` | `LocalUser` as JSON object |
| `prefConversations` | `List<Conversation>` as JSON array |
| `ahoy_msgs_{convId}` | `List<Message>` as JSON array (one key per conversation) |
| `prefOffGrid` | bool |
| `prefReceiveOff` | bool |
| `prefBleEnabled` | bool (default: true) |
| `prefLanEnabled` | bool (default: true) |
| `prefWifiDirectEnabled` | bool (default: true) |
| `prefBlockedUuids` | `List<String>` (UUIDs) as JSON array |

Completely cleared on sign-out via `PrefsStore.clearAll()`.

### ConversationStore (`lib/Ahoy/services/chat/conversation_store.dart`)
Wraps PrefsStore with an **async mutex** (`_withLock`) so concurrent send + receive operations don't lose updates via read-modify-write races.

`loadAll()` filters `isDeleted == true` entries and sorts by `lastMessageAt` descending.

### MessageStore (`lib/Ahoy/services/chat/message_store.dart`)
Per-conversation async mutex (`_withLock`) serialises all read-modify-write operations, matching the pattern in `ConversationStore`. Deduplicates by `message.id` on `addMessage()`. Messages sorted by `timestamp` ascending on load.

---

## 23. Android Native Bridge

**File:** `android/app/src/main/kotlin/com/example/ahoy/MainActivity.kt`

### MethodChannel: `"wifi_direct"`

**Dart → Kotlin:**
| Method | Arguments | Returns |
|--------|-----------|---------|
| `initialize` | — | `bool` — starts TCP ServerSocket on port 8765 |
| `discoverPeers` | — | `null` — triggers WifiP2pManager.discoverPeers() |
| `connect` | `{deviceAddress: String}` | `null` — initiates P2P connection |
| `sendData` | `{data: ByteArray, recipientIP?: String}` | `bool` — sends to explicit IP or broadcasts |
| `disconnect` | — | `null` — removes P2P group, fires onDisconnected |

**Kotlin → Dart (invoke on UI thread):**
| Callback | Payload | When |
|----------|---------|------|
| `onPeersDiscovered` | `List<Map<deviceName, deviceAddress, status>>` | WIFI_P2P_PEERS_CHANGED broadcast |
| `onConnectionEstablished` | `{isGroupOwner: bool, address: String}` | WIFI_P2P_CONNECTION_CHANGED broadcast |
| `onDataReceived` | `{data: ByteArray, senderIP: String}` | TCP packet fully received |
| `onConnectionFailed` | `Int` (reason code) | connect() failure |
| `onDisconnected` | `null` | group removed or connection lost |

### MethodChannel: `"ble_advertiser"`

**Dart → Kotlin:**
| Method | Arguments | Returns |
|--------|-----------|---------|
| `startAdvertising` | `{serviceUuid: String, payload?: ByteArray}` | `bool` — opens GATT server + starts LE advertising |
| `stopAdvertising` | — | `null` — stops advertiser, closes GATT server |

**Kotlin → Dart:**
| Callback | Payload | When |
|----------|---------|------|
| `onBleChunkReceived` | `{chunk: String, deviceAddress: String}` | Central writes to GATT characteristic |

### WifiDirectReceiver (BroadcastReceiver)
```kotlin
Registered in onResume(), unregistered in onPause()
Listens for:
  WIFI_P2P_PEERS_CHANGED_ACTION    → requestPeers() → onPeersDiscovered()
  WIFI_P2P_CONNECTION_CHANGED_ACTION → requestConnectionInfo() → onConnectionInfoAvailable()
```

---

## 24. Data Models Reference

### LocalUser (`lib/Ahoy/models/local_user.dart`)
Own signed-in user. Persisted as JSON in `PrefsStore[prefProfile]`.
| Field | Type | Description |
|-------|------|-------------|
| `id` | String | UUID v4 (stable identifier) |
| `username` | String | Display name shown to peers |
| `bio` | String? | Optional freetext biography |
| `gender` | Gender | Male / Female / Unspecified |
| `avatarPath` | String? | Local file path to avatar JPEG |
| `interests` | List\<String\> | Selected interest tags |
| `publicKeyPEM` | String | RSA-2048 public key (shared with peers) |
| `shortId` | String | 6-char code derived from UUID |
| `statusMessage` | String? | Short status shown in Discover |
| `createdAt` | DateTime | Account creation timestamp |
| `biometricEnabled` | bool | Whether biometric login is enabled |

### NearbyPeer (`lib/Ahoy/models/nearby_peer.dart`)
In-memory representation of a discovered peer. Never persisted directly.
| Field | Type | Description |
|-------|------|-------------|
| `uuid` | String | Canonical Ahoy UUID (may be MAC until resolved) |
| `shortId` | String | 6-char code |
| `displayName` | String | Peer's display name |
| `transport` | TransportMode | Best (highest-priority) current transport |
| `transports` | Set\<TransportMode\> | All transports currently active for this peer |
| `rssi` | int? | BLE signal strength (unused in UI currently) |
| `lastSeen` | DateTime | Time of last announcement; used for stale detection |
| `isBlocked` | bool | Whether this peer is blocked |
| `statusMessage` | String? | Peer's status message |
| `publicKeyPEM` | String? | Peer's public key (for E2EE) |
`isStale` getter: `DateTime.now().difference(lastSeen).inSeconds > 30`

### Conversation (`lib/Ahoy/models/conversation.dart`)
Chat thread metadata. Persisted in `PrefsStore[prefConversations]`.
| Field | Type | Description |
|-------|------|-------------|
| `id` | String | `conversationId(myUuid, peerUuid)` — deterministic 32-char hex |
| `peerUuid` | String | Peer's canonical UUID |
| `peerDisplayName` | String | Cached peer name |
| `peerShortId` | String | Cached peer shortId |
| `peerPublicKeyPEM` | String? | Cached peer public key (updated on each receive) |
| `lastTransport` | TransportMode | Transport used for last message |
| `isBlocked` | bool | Whether conversation is blocked |
| `isDeleted` | bool | Soft-delete flag |
| `unreadCount` | int | Messages received since last `markRead()` |
| `createdAt` | DateTime | Conversation creation time |
| `lastMessageAt` | DateTime? | Timestamp of most recent message |
| `lastMessagePreview` | String? | Preview text or `[image]` / `[voice]` |

### Message (`lib/Ahoy/models/message.dart`)
Single message. Persisted in `PrefsStore[ahoy_msgs_{convId}]`.
| Field | Type | Description |
|-------|------|-------------|
| `id` | String | UUID v4 |
| `conversationId` | String | Parent conversation ID |
| `senderId` | String | UUID of sender (own UUID for sent, peer UUID for received) |
| `type` | MessageType | text / image / voice |
| `content` | String | Text content, or local file path for media |
| `replyToId` | String? | ID of replied-to message |
| `replyToPreview` | String? | First 80 chars of replied-to content |
| `status` | MessageStatus | sending → sent / failed |
| `transport` | TransportMode | Transport used to send/receive |
| `timestamp` | DateTime | Message creation time |
| `isEncrypted` | bool | Whether content was encrypted in transit |

### PeerProfile (`lib/Ahoy/models/peer_profile.dart`)
Serializable peer identity for over-the-air transmission. Superset of what fits in BLE scan response.
| Field | Type | Description |
|-------|------|-------------|
| `uuid` | String | Ahoy UUID |
| `shortId` | String | 6-char code |
| `displayName` | String | Display name |
| `bio` | String? | Biography |
| `gender` | Gender | Gender preference |
| `avatarBase64` | String? | Base64-encoded JPEG (max 40 KB) |
| `interests` | List\<String\> | Interest tags |
| `publicKeyPEM` | String | RSA public key |
| `statusMessage` | String? | Status |

---

## 25. Enums Reference

**`TransportMode`** — controls routing priority and media capability:
| Value | Priority | Media? | How established |
|-------|----------|--------|-----------------|
| `wifiDirect` | 0 (best) | yes | Android WiFi P2P group |
| `lan` | 1 | yes | UDP broadcast on local network |
| `ble` | 2 | no | Bluetooth LE GATT |
| `none` | 3 | — | Peer not reachable |

**`MessageType`** — controls payload encoding:
| Value | Encoding | Restriction |
|-------|----------|-------------|
| `text` | raw string | any transport |
| `image` | base64-encoded JPEG file | LAN or WiFi Direct only |
| `voice` | base64-encoded AAC file | LAN or WiFi Direct only |

**`MessageStatus`** — shown as icon on message bubble:
| Value | Icon | Meaning |
|-------|------|---------|
| `sending` | spinner / clock | awaiting transport ACK |
| `sent` | ✓ | delivered to peer |
| `failed` | ✗ | transport returned false |

**`Gender`** — profile and avatar display:
| Value | Avatar color |
|-------|-------------|
| `male` | blue |
| `female` | pink |
| `unspecified` | purple |

**`PeerStatus`** — declared but not yet fully wired in UI:
| Value | Meaning |
|-------|---------|
| `available` | Normal |
| `busy` | Do Not Disturb |
| `offGrid` | Not broadcasting |

---

## 26. Android Permissions

Declared in `android/app/src/main/AndroidManifest.xml`:

| Permission | API Level | Why Required |
|-----------|-----------|-------------|
| `BLUETOOTH` | ≤ 30 | Legacy BLE API (pre-Android 12) |
| `BLUETOOTH_ADMIN` | ≤ 30 | Legacy BLE control (pre-Android 12) |
| `BLUETOOTH_SCAN` | ≥ 31 | BLE scanning (Android 12+) |
| `BLUETOOTH_CONNECT` | ≥ 31 | GATT connections (Android 12+) |
| `BLUETOOTH_ADVERTISE` | ≥ 31 | BLE advertising as peripheral (Android 12+) |
| `ACCESS_FINE_LOCATION` | all | Required by Android for BLE scanning at any API level |
| `ACCESS_COARSE_LOCATION` | all | Coarse fallback |
| `CAMERA` | all | Photo capture for image messages and avatar |
| `RECORD_AUDIO` | all | Voice message recording |
| `ACCESS_WIFI_STATE` | all | Read WiFi state for P2P group management |
| `CHANGE_WIFI_STATE` | all | Manage WiFi P2P groups |
| `CHANGE_NETWORK_STATE` | all | Socket binding for WiFi Direct |
| `ACCESS_NETWORK_STATE` | all | Detect active network interface |
| `INTERNET` | all | TCP sockets for LAN and WiFi Direct |
| `NEARBY_WIFI_DEVICES` | ≥ 33 | Android 13+ scoped WiFi access (`neverForLocation` — avoids location prompt) |
| `USE_BIOMETRIC` | all | Fingerprint / face authentication |
| `USE_FINGERPRINT` | all | Legacy fingerprint support |
| `READ_MEDIA_IMAGES` | ≥ 33 | Gallery image picker (Android 13+) |
| `READ_MEDIA_AUDIO` | ≥ 33 | Audio file access (Android 13+) |
| `READ_EXTERNAL_STORAGE` | ≤ 32 | Media access fallback (pre-Android 13) |

Hardware features declared `android:required="false"` so app installs on devices without camera or BLE.

---

## 27. Key Dependencies

| Package | Version | Used For |
|---------|---------|----------|
| `provider` | ^6.1.2 | State management (all 5 ChangeNotifier providers) |
| `flutter_secure_storage` | ^9.2.2 | Android Keystore-backed storage for RSA keys and password hash |
| `shared_preferences` | ^2.3.5 | Profile, conversations, messages, all settings flags |
| `local_auth` | ^2.3.0 | Biometric sign-in (fingerprint / face) |
| `uuid` | ^4.5.1 | UUID v4 generation for user ID and message ID |
| `crypto` | ^3.0.6 | SHA-256 for conversation ID and short ID derivation |
| `encrypt` | ^5.0.3 | AES-256-GCM message encryption |
| `pointycastle` | ^3.9.1 | RSA-2048 key generation and RSA-OAEP key wrapping |
| `flutter_blue_plus` | ^1.35.5 | BLE scanning, GATT discovery, characteristic writes |
| `permission_handler` | ^11.3.0 | Runtime permission requests |
| `image_picker` | ^1.1.2 | Gallery and camera capture |
| `record` | ^6.2.0 | Voice message recording (AAC) |
| `audioplayers` | ^6.4.0 | Voice message playback |
| `path_provider` | ^2.1.5 | App documents directory for media and avatar files |
| `flutter_svg` | ^2.1.0 | SVG assets |

---

## 28. Getting Started

**Requirements:**
- Flutter 3.x
- Android 8.0+ (API 26+) — WiFi Direct requires Android 4.0+ but BLE peripheral mode requires Android 5.0+
- Two physical Android devices (emulators do not support WiFi Direct or BLE advertising)

**Run:**
```bash
flutter pub get
flutter run
```

**Analyze:**
```bash
flutter analyze        # should report: No issues found
```

**Build release APK:**
```bash
flutter build apk --release
```

**Recommended test setup:**
1. Install on two devices on the same WiFi network
2. Sign up on each with different usernames
3. One device will appear in the other's Discover tab within ~5 seconds (LAN) or up to 30 seconds (WiFi Direct / BLE)
4. Tap "Chat" → send a message → verify it appears on the other device
5. Toggle transports in Settings to test each path independently

---

## License

GPL v3 — see `LICENSE`. Commercial licensing available.
