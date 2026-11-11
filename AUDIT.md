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
| M-3 | "Sent" = transport accepted bytes. No ACK, no retry queue, no `delivered`/`read` statuses. | `lan_transport.dart:327-330`, `ble_transport.dart:335-348` |
| M-4 | LAN TCP server binds all interfaces (`anyIPv4`); Kotlin WD `ServerSocket(P2P_PORT)` likewise — injectable chat from unrelated joined networks. | `lan_transport.dart:113-116`, `MainActivity.kt:287` |
| M-5 | Announced TCP port trusted (range-checked only) → victim connects to arbitrary host:port with attacker-chosen payload on send. | `lan_transport.dart:194-198` |
| M-6 | No key-verification UX (no fingerprint/safety number) — users cannot detect impersonation. | — |

### Low

1. macOS release entitlements lacked `network.server`/`network.client` — sandboxed release builds could not run the LAN transport. **FIXED in this audit** (both `DebugProfile.entitlements` and `Release.entitlements`).
2. Thread-per-connection in Kotlin WD server; `connectedClients` only cleared on full disconnect (connection-flood DoS surface). `MainActivity.kt:294-295`
3. Dead code removed: `NearbyPeer.rssi` (never populated) **FIXED**; remaining: `PeerProfile` model, `bleProfileCharUuid`, `ProfileService.avatarBase64` — the BLE profile characteristic is never read/written by any transport.
4. README drift: documented non-existent `PeerStatus` enum and functional `rssi`. **FIXED in this audit.**
5. `test/widget_test.dart` was a placeholder. **FIXED** — real tests for `TransportBadge(s)` ordering/rendering and `PasswordField` validation/visibility toggle.
6. `ChatProvider.sendMessage` with a cold cache inserts only the new message (`chat_provider.dart:108`), hiding history until cache invalidation (UI race; inbound path already does `remove()`).
7. `decryptFromPeer` throws `CryptoNotInitialized` for wrong envelope version (`crypto_service.dart:149`) — misleading error type, benign behavior.
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

1. ~~H-1~~ (done) → 2. ~~H-2~~ (done: signed announcements, shortId↔uuid consistency, safety numbers) → 3. ~~M-1/M-2~~ (done: v=3 sealed wire format; sender/conv binding + freshness window) → 4. M-3 (ACK + outbox) → 5. M-4/M-5 (interface-scoped binds, fixed port) → 6. hygiene leftovers (L-3/L-6/L-7).
