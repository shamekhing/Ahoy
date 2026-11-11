# Ahoy — Security & Code Audit

**Date:** 2026-11-11 · **Commit:** 496ebc2 · **Scope:** `lib/` (57 Dart files), `android/app/src/main/kotlin/com/ahoy/app/MainActivity.kt`, platform configs, tests, `pubspec.lock` · **Method:** read-only static review (no Flutter SDK available in audit environment; baseline `flutter analyze`/`test` not run — run locally)

## Verdict

The crypto architecture is sound and well-hardened: RSA-OAEP/AES-GCM hybrid envelopes, PBKDF2 (310k iters, constant-time compare), TOFU key pinning, AES-256-GCM at-rest encryption with plaintext→encrypted migration, locked-down Android backup rules, enforced release signing, debug-gated logging, transport bounds checks with test coverage. **The weak link is identity, not cryptography:** nothing binds a peer's UUID/name to a public key, and (before this audit's fix) unkeyed first-contact messages were accepted with no verification.

## Findings

### High

- **H-1 — First-contact messages accepted with zero authentication.** `_verifyInboundSignature` returned `true` when no trusted key existed (`chat_service.dart`). Any device on a transport (LAN TCP `0.0.0.0:45679`, WiFi Direct port 8765, BLE GATT write) could inject plaintext messages spoofing `from`/`fromName`. **FIXED in this audit** — unkeyed inbound payloads are now dropped before any store writes; regression test added (`test/chat_service_key_pinning_test.dart`).
- **H-2 — No UUID↔key binding (TOFU without pin-at-discovery).** First signed message pins the key presented in the payload; announcements carry unauthenticated `publicKeyPEM` (`lan_transport.dart`). A first-contact MITM silently pins their key; an attacker announcing a victim's `shortId` poisons `_shortIdToUuid` (`discovery_service.dart`) and hijacks the alias via `TransportManager.registerAlias`. **Implemented in this audit:** LAN/WD announcements now carry an RSA-SHA256 signature over the frozen identity field set (`CryptoService.announcementMaterial`); `DiscoveryProvider._acceptAnnouncement` drops announcements whose `shortId` ≠ `shortIdFromUuid(uuid)` (deterministic → forgery-proof) and drops keyed announcements without a valid signature; BLE scan-response announcements stay display-only (13-byte budget) with identity bound at the first signed chat message. A 60-digit Signal-style safety number (`CryptoService.fingerprintFromPublicKey`) is shown in My Profile and Peer Profile so first-contact MITM is detectable out-of-band.

### Medium

| # | Finding | Evidence |
|---|---------|----------|
| M-1 | **FIXED (v=3 sealed format):** wire carries only `{v:3, from, ct}` — identity, convId, timestamp, names and content are inside the encrypted+signed blob. Legacy flat format remains only as the no-peer-key fallback (still identity-bound and signed). | `chat_service.dart _buildPayload`, `transport_manager.dart send` |
| M-2 | **FIXED:** signed `senderUuid` cross-checked against wire identity; `convId` bound to the computed conversation (kills cross-conversation replay); ±15 min freshness window on signed timestamps; msgId length/charset validation. | `chat_service.dart onInboundPacket` |
| M-3 | **FIXED:** receivers return a sealed, signed delivery ack; senders upgrade `sent → delivered` after verification (new `MessageStatus.delivered`, ✓✓ icon). Failed text sends enter a per-peer outbox (max 50, max 3 attempts) and are retried automatically when a discovery announcement shows the peer back. | `chat_service.dart _sendAck/_handleInboundAck/retryPendingFor` |
| M-4 | **FIXED:** LAN announces/connections are filtered to the host's own interface subnets, and TCP connections are only accepted from /24 subnets that actually announced themselves (loopback exempt for local tooling). Kotlin WD server rejects connections outside the group subnet derived from `WifiP2pInfo.groupOwnerAddress` (fail-closed), and `cmdSendData` only sends into that subnet. | `lan_transport.dart`, `MainActivity.kt` |
| M-5 | **FIXED:** the announce no longer carries a TCP port and inbound announces never trusted it — the messaging port is fixed (45679) on both ends, eliminating the arbitrary host:port connect vector. | `lan_transport.dart _broadcast/_onUdpDatagram` |
| M-6 | **FIXED:** My Profile shows the own-key fingerprint (identity card) and Peer Profile shows a **combined per-conversation safety number** (`CryptoService.safetyNumberFor` — order-independent over both pinned/announced keys, so both devices compute the identical 60 digits). Peer Profile prefers the pinned conversation key. Read aloud out-of-band to detect impersonation; chat-screen integration remains a UX nicety. | `crypto_service.dart`, `peer_profile_screen.dart`, `my_profile_screen.dart` |
### Low

1. macOS release entitlements lacked `network.server`/`network.client` — sandboxed release builds could not run the LAN transport. **FIXED in this audit** (both `DebugProfile.entitlements` and `Release.entitlements`).
2. **FIXED:** incoming WD connections are handled on a bounded 4-thread pool instead of thread-per-connection, and `connectedClients` is a TTL-pruned (10 min) `ConcurrentHashMap<String, Long>` instead of an ever-growing set. `MainActivity.kt`
3. **FIXED:** removed all dead profile-broadcast code — `PeerProfile` model, `bleProfileCharUuid`, `ProfileService.avatarBase64` (and its test) — the BLE profile characteristic remains unwired by design; `NearbyPeer.rssi` was removed in the first pass.
4. README drift: documented non-existent `PeerStatus` enum and functional `rssi`. **FIXED in this audit.** (The stale `com.example` paths in README were also fixed during the M-4/M-5 pass.)
5. `test/widget_test.dart` was a placeholder. **FIXED** — real tests for `TransportBadge(s)` ordering/rendering and `PasswordField` validation/visibility toggle.
6. **FIXED:** `ChatProvider.sendMessage` now invalidates the message cache — mirroring the inbound path — instead of seeding a cold cache with only the new message.
7. **FIXED:** wrong envelope versions now throw the new `CryptoFormatError` instead of the misleading `CryptoNotInitialized` (which stays reserved for unloaded key material), with a regression test.
8. Dependencies: `encrypt` 5.0.3 is effectively unmaintained (routes through pointycastle 3.9.1 — fine today, watch supply chain); `flutter_secure_storage` 9.2.4 uses `EncryptedSharedPreferences`, deprecated by Google in `androidx.security` — watch the plugin's migration. Other pins current; no known CVEs.

## Verified solid

- Password hashing: PBKDF2-HMAC-SHA256, 310k iters, 16-byte salt, isolate off UI thread, constant-time compare, legacy upgrade path (`crypto_service.dart:48-96`)
- Hybrid E2EE: RSA-2048-OAEP(SHA-256) wraps per-message AES-256-GCM key, versioned envelope (`crypto_service.dart:114-158`)
- Pinning: key changes ignored, canonical PEM compare, tested
- At-rest: profile/conversations/messages AES-256-GCM; media `.ahoyenc` + iOS backup exclusion; migrator covered by tests
- Bounds: LAN 16MB cap + per-byte buffer cap + 8 msgs/conn + 10s idle; WD length-prefix + 10MB + `soTimeout`; BLE chunk/assembly bounds + eviction — dedicated tests exist
- Platform: `allowBackup=false` + full-exclusion backup/data-extraction rules, enforced release signing (build fails without `key.properties`), minimal permissions, all iOS usage descriptions, `com.ahoy.app` consistent (no `com.example` anywhere)

## Roadmap scorecard (external prior audit)

| Claim | Verdict |
|---|---|
| Identity gap / unsigned envelope fields | Confirmed (H-2, M-1); unkeyed-accept gap fixed as H-1 |
| Plaintext wire metadata | Confirmed (M-1) |
| No ACK/retry/queue | Confirmed (M-3) |
| `com.example.ahoy` mismatch | Refuted — already fixed |
| README drift / placeholder widget test / unused fields | Confirmed — fixed in this audit |
| WiFi Direct stub on iOS (+ BLE advertiser Android-only) | Confirmed; macOS additionally broken pre-fix |
| Hand-rolled DER encoder | Confirmed (`crypto_service.dart:274-333`); correct on review but lacks dedicated round-trip/property tests — candidate for external crypto review |
| Forward secrecy (X25519 handshake) | Absent; do after H-2, behind a protocol version field |

## Recommended fix order (remaining)

1. ~~H-1~~ (done) → 2. ~~H-2~~ (done: signed announcements, shortId↔uuid consistency, safety numbers) → 3. ~~M-1/M-2~~ (done: v=3 sealed wire format; sender/conv binding + freshness window) → 4. ~~M-3~~ (done: signed sealed acks, `delivered` status, retry outbox) → 5. ~~M-4/M-5~~ (done: subnet-scoped LAN + WD, fixed messaging port) → 6. ~~hygiene leftovers~~ (done: bounded WD pool + TTL client map, dead profile code removed, cache race fixed, CryptoFormatError).

**All High, Medium and Low findings from this audit are resolved.** Remaining recommendations are process-level: real-device transport testing and an external review of the hand-rolled DER encoder before a wider release.

---

# Second External Review (follow-up audit)

A second review confirmed the primitives and prior fixes, and raised 7 High findings — all verified against the code and fixed:

| # | Finding | Fix |
|---|---------|-----|
| 1 | Plaintext fallback contradicted E2EE (BLE first contact sent raw content) | **Signed identity handshake:** keyless sends now transmit a signed identity (never content), queue the message, and flush sealed once the peer's signed identity arrives. `_buildPayload` throws instead of degrading to plaintext. |
| 2 | Erase-then-register bricked the app (stale in-memory at-rest key) | `LocalDataCrypto.reset()` installs a fresh persisted key on sign-out; sign-out also deletes the account's media files. |
| 3 | Sign-out wasn't a real reset | RootScreen tears down the session (transports flag, subscriptions, ChatProvider/DiscoveryProvider/Profile state); ChatService/ChatProvider/DiscoveryProvider gained `reset()`; re-sign-in re-initialises with the new identity. |
| 4 | Profile edits signed the stale identity while broadcasting the new one | `TransportManager.startAdvertising` refreshes the cached identity before signing; regression test proves the signature matches the advertised name. |
| 5 | Routing state written before verification | LAN announces require key + valid signature before `_peerConns`; WD learns routes only from verified `wdIdentity` and drops unknown-uuid packets; `TransportManager` records transports only for verified announcements; keyless announces are BLE-only. |
| 6 | Grindable shortId collisions could hijack peers | `DiscoveryService` rejects shortId merges when keys differ and never lets a different key overwrite an existing verified key. |
| 7 | First-contact pinning trusted the sender | Discovery-verified keys are registered (`registerVerifiedPeerKey`); first contacts pinning a different key are dropped before any state is written. |

Medium/Low/hygiene findings from this second review are queued for the next pass. Validated: `flutter analyze` clean, `flutter test` 65/65 passing.
