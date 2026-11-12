# Ahoy Security & Code Audit

**Date:** 2026-11-11 · **Commit:** 496ebc2 · **Scope:** `lib/` (57 Dart files), `android/app/src/main/kotlin/com/ahoy/app/MainActivity.kt`, platform configs, tests, `pubspec.lock` · **Method:** read-only static review (no Flutter SDK available in audit environment; baseline `flutter analyze`/`test` not run run locally)

## Verdict

The crypto architecture is sound and well-hardened: RSA-OAEP/AES-GCM hybrid envelopes, PBKDF2 (310k iters, constant-time compare), TOFU key pinning, AES-256-GCM at-rest encryption with plaintext→encrypted migration, locked-down Android backup rules, enforced release signing, debug-gated logging, transport bounds checks with test coverage. **The weak link is identity, not cryptography:** nothing binds a peer's UUID/name to a public key, and (before this audit's fix) unkeyed first-contact messages were accepted with no verification.

## Findings

### High

- **H-1 First-contact messages accepted with zero authentication.** `_verifyInboundSignature` returned `true` when no trusted key existed (`chat_service.dart`). Any device on a transport (LAN TCP `0.0.0.0:45679`, WiFi Direct port 8765, BLE GATT write) could inject plaintext messages spoofing `from`/`fromName`. **FIXED in this audit** unkeyed inbound payloads are now dropped before any store writes; regression test added (`test/chat_service_key_pinning_test.dart`).
- **H-2 No UUID↔key binding (TOFU without pin-at-discovery).** First signed message pins the key presented in the payload; announcements carry unauthenticated `publicKeyPEM` (`lan_transport.dart`). A first-contact MITM silently pins their key; an attacker announcing a victim's `shortId` poisons `_shortIdToUuid` (`discovery_service.dart`) and hijacks the alias via `TransportManager.registerAlias`. **Implemented in this audit:** LAN/WD announcements now carry an RSA-SHA256 signature over the frozen identity field set (`CryptoService.announcementMaterial`); `DiscoveryProvider._acceptAnnouncement` drops announcements whose `shortId` ≠ `shortIdFromUuid(uuid)` (deterministic → forgery-proof) and drops keyed announcements without a valid signature; BLE scan-response announcements stay display-only (13-byte budget) with identity bound at the first signed chat message. A 60-digit Signal-style safety number (`CryptoService.fingerprintFromPublicKey`) is shown in My Profile and Peer Profile so first-contact MITM is detectable out-of-band.

### Medium

| # | Finding | Evidence |
|---|---------|----------|
| M-1 | **FIXED (v=3 sealed format):** wire carries only `{v:3, from, ct}` identity, convId, timestamp, names and content are inside the encrypted+signed blob. Legacy flat format remains only as the no-peer-key fallback (still identity-bound and signed). | `chat_service.dart _buildPayload`, `transport_manager.dart send` |
| M-2 | **FIXED:** signed `senderUuid` cross-checked against wire identity; `convId` bound to the computed conversation (kills cross-conversation replay); ±15 min freshness window on signed timestamps; msgId length/charset validation. | `chat_service.dart onInboundPacket` |
| M-3 | **FIXED:** receivers return a sealed, signed delivery ack; senders upgrade `sent → delivered` after verification (new `MessageStatus.delivered`, ✓✓ icon). Failed text sends enter a per-peer outbox (max 50, max 3 attempts) and are retried automatically when a discovery announcement shows the peer back. | `chat_service.dart _sendAck/_handleInboundAck/retryPendingFor` |
| M-4 | **FIXED:** LAN announces/connections are filtered to the host's own interface subnets, and TCP connections are only accepted from /24 subnets that actually announced themselves (loopback exempt for local tooling). Kotlin WD server rejects connections outside the group subnet derived from `WifiP2pInfo.groupOwnerAddress` (fail-closed), and `cmdSendData` only sends into that subnet. | `lan_transport.dart`, `MainActivity.kt` |
| M-5 | **FIXED:** the announce no longer carries a TCP port and inbound announces never trusted it the messaging port is fixed (45679) on both ends, eliminating the arbitrary host:port connect vector. | `lan_transport.dart _broadcast/_onUdpDatagram` |
| M-6 | **FIXED:** My Profile shows the own-key fingerprint (identity card) and Peer Profile shows a **combined per-conversation safety number** (`CryptoService.safetyNumberFor` order-independent over both pinned/announced keys, so both devices compute the identical 60 digits). Peer Profile prefers the pinned conversation key. Read aloud out-of-band to detect impersonation; chat-screen integration remains a UX nicety. | `crypto_service.dart`, `peer_profile_screen.dart`, `my_profile_screen.dart` |
### Low

1. macOS release entitlements lacked `network.server`/`network.client` sandboxed release builds could not run the LAN transport. **FIXED in this audit** (both `DebugProfile.entitlements` and `Release.entitlements`).
2. **FIXED:** incoming WD connections are handled on a bounded 4-thread pool instead of thread-per-connection, and `connectedClients` is a TTL-pruned (10 min) `ConcurrentHashMap<String, Long>` instead of an ever-growing set. `MainActivity.kt`
3. **FIXED:** removed all dead profile-broadcast code `PeerProfile` model, `bleProfileCharUuid`, `ProfileService.avatarBase64` (and its test) the BLE profile characteristic remains unwired by design; `NearbyPeer.rssi` was removed in the first pass.
4. README drift: documented non-existent `PeerStatus` enum and functional `rssi`. **FIXED in this audit.** (The stale `com.example` paths in README were also fixed during the M-4/M-5 pass.)
5. `test/widget_test.dart` was a placeholder. **FIXED** real tests for `TransportBadge(s)` ordering/rendering and `PasswordField` validation/visibility toggle.
6. **FIXED:** `ChatProvider.sendMessage` now invalidates the message cache mirroring the inbound path instead of seeding a cold cache with only the new message.
7. **FIXED:** wrong envelope versions now throw the new `CryptoFormatError` instead of the misleading `CryptoNotInitialized` (which stays reserved for unloaded key material), with a regression test.
8. Dependencies: `encrypt` 5.0.3 is effectively unmaintained (routes through pointycastle 3.9.1 fine today, watch supply chain); `flutter_secure_storage` 9.2.4 uses `EncryptedSharedPreferences`, deprecated by Google in `androidx.security` watch the plugin's migration. Other pins current; no known CVEs.

## Verified solid

- Password hashing: PBKDF2-HMAC-SHA256, 310k iters, 16-byte salt, isolate off UI thread, constant-time compare, legacy upgrade path (`crypto_service.dart:48-96`)
- Hybrid E2EE: RSA-2048-OAEP(SHA-256) wraps per-message AES-256-GCM key, versioned envelope (`crypto_service.dart:114-158`)
- Pinning: key changes ignored, canonical PEM compare, tested
- At-rest: profile/conversations/messages AES-256-GCM; media `.ahoyenc` + iOS backup exclusion; migrator covered by tests
- Bounds: LAN 16MB cap + per-byte buffer cap + 8 msgs/conn + 10s idle; WD length-prefix + 10MB + `soTimeout`; BLE chunk/assembly bounds + eviction dedicated tests exist
- Platform: `allowBackup=false` + full-exclusion backup/data-extraction rules, enforced release signing (build fails without `key.properties`), minimal permissions, all iOS usage descriptions, `com.ahoy.app` consistent (no `com.example` anywhere)

## Roadmap scorecard (external prior audit)

| Claim | Verdict |
|---|---|
| Identity gap / unsigned envelope fields | Confirmed (H-2, M-1); unkeyed-accept gap fixed as H-1 |
| Plaintext wire metadata | Confirmed (M-1) |
| No ACK/retry/queue | Confirmed (M-3) |
| `com.example.ahoy` mismatch | Refuted already fixed |
| README drift / placeholder widget test / unused fields | Confirmed fixed in this audit |
| WiFi Direct stub on iOS (+ BLE advertiser Android-only) | Confirmed; macOS additionally broken pre-fix |
| Hand-rolled DER encoder | Confirmed (`crypto_service.dart:274-333`); correct on review but lacks dedicated round-trip/property tests candidate for external crypto review |
| Forward secrecy (X25519 handshake) | Absent; do after H-2, behind a protocol version field |

## Recommended fix order (remaining)

1. ~~H-1~~ (done) → 2. ~~H-2~~ (done: signed announcements, shortId↔uuid consistency, safety numbers) → 3. ~~M-1/M-2~~ (done: v=3 sealed wire format; sender/conv binding + freshness window) → 4. ~~M-3~~ (done: signed sealed acks, `delivered` status, retry outbox) → 5. ~~M-4/M-5~~ (done: subnet-scoped LAN + WD, fixed messaging port) → 6. ~~hygiene leftovers~~ (done: bounded WD pool + TTL client map, dead profile code removed, cache race fixed, CryptoFormatError).

**All High, Medium and Low findings from this audit are resolved.** Remaining recommendations are process-level: real-device transport testing and an external review of the hand-rolled DER encoder before a wider release.

---

# Second External Review (follow-up audit)

A second review confirmed the primitives and prior fixes, and raised 7 High findings all verified against the code and fixed:

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

---

# Third External Review (follow-up audit)

A third review found ordering and edge-case issues. Priority items and the accepted ones are fixed:

| # | Finding | Fix |
|---|---------|-----|
| 1 | Acks could flip non-sent messages to `delivered` (replayed/forged-target acks) | `_handleInboundAck` now requires the acked msgId to exist in the conversation with status `sent` (or `delivered`, idempotent); anything else is ignored. |
| 2 | Replay after conversation deletion resurrected messages | Bounded (512) session seen-msgId cache; only authenticated messages enter it, so garbage cannot flush it. Test: replay-after-delete drops. |
| 3 | Conversation read-modify-write raced (Block/markRead clobbered) | `ConversationStore.mutateOrCreate` performs the read-modify-write inside the store lock; `_updateConversationOnSend/OnReceive` use it. |
| 4 | Block not enforced on the sending path | `ChatService` holds the live blocked set (`attachBlockedPeers`, wired from DiscoveryProvider via ChatProvider) and `sendMessage` rejects blocked peers. |
| 5 | Deleted conversations silently retain the pinned key | Documented as intentional (re-contact pinning) in code. |
| 8 | GATT callback raced `bleGattServer` nulling | Server reference captured locally before `sendResponse`. |
| 9/10/11/12 | Docs + build hygiene | README TOC stray link removed, §10g corrected to body-text placeholder + outbound-send rejection noted, §15 legacy-fallback text replaced with the throw + identity-handshake reality; `build/` gitignored and the committed Gradle report removed from the index; Gradle heap reduced to CI-safe sizes; `defaultAvatarAsset` dead code removed (referenced non-existent assets); launcher_icons switched to the raster PNG and the bogus `web:` section dropped; `DiscoveryControls` (unused, out-of-sync copy) deleted; dark-mode launch flash fixed with a `drawable-night` background. |

Not actioned (accepted as-is): BLE assembly-eviction cost at the 16-assembly cap, `connectedClients` prune micro-race (non-security), identity send immediately after sign-out (in-flight race, benign). Validated: `flutter analyze` clean, `flutter test` 68/68 passing.

---

# Fourth External Review (WiFi Direct transport focus)

A transport-focused review of `wifi_direct_transport.dart` raised three findings all verified and fixed:

| # | Finding | Fix |
|---|---------|-----|
| 1 | `onConnectionFailed` guessed the failed peer from the single `_pendingConnectAddress`; concurrent in-flight connects stale-overwrite it, so the wrong address was removed from `_connectingAddresses` and another peer stayed wedged | Replaced the set + pending-address bookkeeping with a TTL-based `_connectingAttempts` map (30 s, injectable): attempts are pruned on discovery cycles, cleared when the group forms, and a thrown connect removes its own address. The guessing handler was deleted Kotlin does not identify the failed device, so expiry is the only honest bookkeeping. |
| 2 | Identity completion removed an *IP address* from a MAC-keyed set, so the entry never cleared and reconnects stayed blocked until a group teardown | The mismatched removal was deleted; TTL expiry handles retryability. |
| 3 | `dispose()` never tore down the native group/server socket | `dispose()` now awaits `stopAdvertising()` (which invokes the Kotlin `disconnect`) before stopping discovery. |

New tests: TTL expiry frees wedged peers, concurrent in-flight attempts are tracked independently (regression for the cross-removal), failed connects free the address for immediate retry. Validated: `flutter analyze` clean, `flutter test` 71/71 passing.

---

# Fifth External Review (merged internal audit plus external static review)

Two independent reviews were merged into one ladder. One commit per step on
`audit/fifth-review`. All steps below are complete; hashes are in the
commit log.

## High findings, fixed

| # | Finding | Fix |
|---|---------|-----|
| H-1 | Voice messages were transmitted empty: `_storedContentForLocalMessage` deleted the recorder temp file before `_buildPayload` re-read the path, and the keyless outbox captured the dead path | `_prepareOutgoingMedia` reads bytes once and returns both the stored path and the wire bytes; `_encodeMediaContent` throws on a missing source; the outbox carries bytes; inbound empty media is dropped |
| H-2 | Identity was never bound to keys: self-signed announcements can claim any UUID, `registerVerifiedPeerKey` overwrote unconditionally and ran before the DiscoveryService veto, WiFi Direct routing was last-writer-wins | `PeerTrustStore` is the single authority (first key wins, conflicts recorded as pendingKey and never applied), discovery keys flow to chat only after the veto with the stored key, identity conflicts are refused without reply or retry, WiFi Direct routes bind to the first verified key, and the UI shows unverified/pinned/verifiedBySafetyNumber with an Identity changed banner |
| H-3 | Off the Grid was not enforced: cold start, pull-to-refresh and profile edit all re-advertised | The flag moved into `TransportManager`; every advertise path is gated, the persisted preference seeds a cold start, and the profile editor uses a flag-aware `refreshAdvertising()` |

## Medium findings, fixed

M-1 iOS Keychain is now `first_unlock_this_device` with a one-time rewrite;
quarantine replaces throwing for undecryptable profile, conversation,
message and media records; a reinstall is detected by a prefs account
marker and the stale Keychain identity is cleared; a one-time snackbar
reports quarantined data. M-2 sign-up refuses when an account exists and
the confirmed replacement wipes the old data. M-3 lock ownership hands off
to the next waiter in both stores. M-4 Receive Off gates the identity
handshake for strangers, and WiFi Direct auto-connect gives up on devices
that never prove they speak Ahoy. M-5 picker copies are deleted after
capture, sign-out sweeps the cache, media encode/decode runs in an isolate.
M-6 the outbox is persisted and orphaned `sending` messages are failed at
startup. M-7 media permissions are gone, BLUETOOTH_SCAN is
neverForLocation and location is scoped to old Android. M-8 session maps
are capped, identity packets are throttled per peer, LAN connections are
capped at 32 with a 20 messages per 10 s per-address window.

## Low findings, fixed or accepted

Fixed: conversation media is swept on delete; the legacy plaintext inbound
path is gone (only sealed v3 chat and ack payloads are accepted); BLE
assemblies are keyed by peer plus UUID message ids; untrusted PEM and
PBKDF2 iteration counts are capped; keyless announcements cannot rename
key-verified peers; enabling biometrics requires a successful credential
check; FLAG_SECURE blocks screenshots in release builds; profile renames
reach identity replies; BLE display names are UTF-8 truncated on character
boundaries and idle GATT connections are released after five minutes; the
migrator runs once behind a prefs marker.

Accepted with rationale (recorded at the call sites): PKCS#1 v1.5
signatures instead of RSA-PSS (both ends must agree on the encoding; PSS is
queued for a coordinated upgrade), no AAD in the GCM envelope (the sealed
payload already signs everything inside it), double RSA verification of
announcements (defense in depth across two state owners), write
amplification from per-message re-encryption of conversation history, the
GATT characteristic writable by any nearby device (bounded by assembly
caps), no BLE advertising or GATT server on iOS (Android-only platform
code), the 8-character minimum password with no change flow, the WiFi
Direct receiver registered only in onResume, and the discovery beacons
themselves (UUID plus public key every 5 s over UDP, shortId plus truncated
display name in the BLE scan response), which are inherent to serverless
proximity discovery and are mitigated by rotating nothing: users opt into
Off the Grid.

Deferred with a recorded blocker: R8/minification stays off because a
release build cannot be validated without `android/key.properties`; the
gradle comment now states the real blocker instead of the doubtful
reflection claim. Verified against the pub cache:
`flutter_secure_storage` 9.2.4 does not deprecate `encryptedSharedPreferences`.

## Documentation drift, fixed

`ahoy_router.dart` deleted (it was referenced nowhere); README no longer
references `discovery_controls.dart` (removed in the third review),
`_maybeStartTransports` (never existed under that name) or
`Navigator.pushNamed`, and the bootstrap constructor listing now includes
keyStore and localDataCrypto.

## Known limitation, recorded

The WiFi Direct platform layer reports no MAC to IP linkage, so the
auto-connect cap (two expired attempts per address per group session)
counts a slow real peer the same as a printer; pull-to-refresh clears the
marks for a manual retry.

## Validation

Every commit ran `flutter analyze` clean and its targeted tests; the full
suite is green at 135 tests on Flutter 3.47.9 / Dart 3.13.7. Gate note: run
the suite without piping so a failing exit code cannot be masked.

---

# Sixth External Review (announcement freshness focus)

A focused review of the post-fifth-review code. Findings and dispositions:

## Fixed

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | High | Announcements had no freshness: a captured announcement replayed from another node's IP repointed the LAN TCP route for a victim UUID | announcementMaterial now includes a timestamp, LAN re-signs every broadcast, all receivers (LAN, WD, TransportManager, DiscoveryProvider) reject anything older than 15 minutes, and LAN routing is keyed like WiFi Direct routing: the first verified announcement fixes the UUID's key and a different key is refused before route state changes |
| 2 | High | The same replay refreshed DiscoveryService lastSeen, keeping departed peers online | Same freshness gate runs in both acceptance layers |
| 3 | High | Signed materials had no domain separation; announcement material had no msgType-like discriminator | Every signed material carries a context prefix: ahoy-announce-v1, ahoy-chat-v3, ahoy-ack-v1, ahoy-identity-v1 |
| 4 | Med | A squatted first key had no user-facing reject path | The Identity changed banner gains a Keep current key action that discards pendingKey; sealing never used the pending key (first-key-wins), so this was UX, not crypto |
| 5 | Med | WiFi Direct send fell back to the group owner's address for unknown UUIDs | Removed: no route means no send; the ack and identity paths only deliver to learned routes |
| 6 | Med | reset() left the identity flood throttle populated; outbox removal on reset was fire-and-forget | reset clears the throttle; the on-disk outbox is covered by signOut's prefs clearAll which precedes any repersist |
| 8 | Med | playAudio would write and play a zero-byte decrypted file (what a quarantined file yields) | Empty bytes refuse to play |
| 9/11/12/14 | Low | Comment grammar, stopScanning guard order, contradictory README requirements sentence, no-AAD trade-off invisible to README readers | All corrected; the encrypt dependency row now points at the recorded trade-off |

## Rejected with evidence

Finding 7 (identity throttle race): the throttle check and the map write in
`_handleInboundIdentity` are adjacent synchronous statements with no await
between them, so Dart's single-threaded event loop cannot interleave two
callers at that point. A burst yields one reply per peer per window, which
is the intended behavior.

## Accepted and recorded

Finding 13: a failed WiFi Direct initialize is not retried by
startScanning; recovery happens on the next discovery cycle or transport
toggle. Also recorded: the sixth round is another coordinated wire change
(previous builds cannot verify announcements or sealed messages from this
one), consistent with the no-compat decision for the legacy inbound path.

## New tests

Stale announcement rejected, conflicting-key announcement refused with the
route intact, announcement signature refused as a chat payload, WiFi Direct
key binding surviving teardown, Keep current key dismissal flow.

## Validation

flutter analyze clean; flutter test 139/139 passing on Flutter 3.47.9 /
Dart 3.13.7.

---

# Seventh Review (external reconciliation + hardening round)

Input: two independent external review drafts (worked from the round-6
summary, not the source) were reconciled line-by-line against the code,
then the confirmed findings were fixed. All spot-checked round-6 claims
were re-verified as present; no High-severity regressions were found.

## Fixed

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | Med-High | A same-key announcement replayed from a neighbouring address within the 15-minute freshness window repointed the LAN TCP route (`_peerConns[uuid]` was overwritten on every valid announcement); the first-key rule bound the key, not the route | Route pinning: a verified announcement only repoints the route when there is no route, when it comes from the pinned address, or when the pinned address is older than the peer expiry window. Plus a bounded (uuid, signature) replay cache checked before RSA verification, so replay floods never reach the crypto layer. Tests: `lan_route_pinning_test.dart` |
| 2 | Med | The LAN TCP idle timeout is attacker defeatable (every byte resets it) and 32 connections × 16 MB unterminated buffers = ~512 MB transient allocation; the byte-by-byte read loop made it worse | Absolute per-connection lifetime cap (60 s, injectable), an aggregate buffer budget across all connections (64 MB, injectable), bulk newline splitting with per-message accounting preserved, and the connection-slot leak on clean peer disconnect fixed. Tests: `lan_tcp_hardening_test.dart` |
| 3 | Med-Low | Accounts created before the PBKDF2 migration kept their unsalted SHA-256 (or 100k-iteration PBKDF2) hash indefinitely unless they happened to sign in again; biometric unlock would have bypassed the upgrade forever | `signInWithBiometric` refuses while the stored hash needs an upgrade, forcing one password sign-in that rewrites it to `pbkdf2:v2:`. Tests: `legacy_hash_gate_test.dart` |
| 4 | Low | Thread ordering trusted the sender-controlled timestamp (skewable within ±15 min) | `Message.receivedAt` receiver-clock field (optional, back-compat with older rows) drives `MessageStore` ordering. Tests: `message_ordering_test.dart` |
| 5 | Low | Inbound messages for a soft-deleted conversation were stored invisibly behind the tombstone (and a post-restart replay within the freshness window could add them) | Inbound for soft-deleted conversations is dropped via `ConversationStore.isSoftDeleted`. Test: `chat_inbound_hardening_test.dart` |
| 6 | Low | Inbound media decoded up to a 16 MB base64 string before the byte cap check | Pre-decode size cap (`maxMediaBytes × 4/3`), so oversized media never pays the isolate spawn. Test: `chat_inbound_hardening_test.dart` |
| 7 | Low | Malformed stored password hashes (odd-length/non-hex salt, wrong digest length) threw out of `verifyPassword` instead of failing closed | Hex/length validation plus try/catch around the isolate: a corrupt hash reads as a wrong password. Tests: `crypto_password_robustness_test.dart` |
| 8 | Low | `PeerTrustStore` eviction could drop a safety-number-verified record when the cap filled with verified entries | Eviction prefers unverified, then pinned; verifiedBySafetyNumber records are evicted only as a last resort. Tests: `peer_trust_eviction_test.dart` |
| 9 | Low | Sync AES-GCM decrypt plus file read inside `MessageBubble.build` janks long threads | `_EncryptedImage` stateful widget decodes once via the async reader; quarantined files render the unavailable placeholder. Tests: `message_bubble_image_test.dart` |
| 10 | Low | `minSdk` followed the Flutter toolchain default although secure storage needs API 23+ | Pinned to 24 with the reason recorded |

## Refuted with evidence

- The identity reply set (`_identityRepliedTo`) is already capped at
  `_maxIdentityPeers` in `chat_service.dart`; the external drafts' claim of
  unbounded growth was incorrect.
- The TOFU first-contact acceptance of a self-signed identity for an unknown
  UUID is the documented design; the mitigation stack (discovery-verified
  keys, first-key-wins, conflict banner, safety numbers) was re-verified.
- `logError` never logs in release builds (`MainActivity.kt` gates on
  `isDebugBuild` before any `Log.e` call).
- A replayed sealed message cannot resurrect a deleted conversation's UI
  record (`copyWith` preserves `isDeleted`); fix #5 closes the residual
  invisible-storage path.

## Documentation drift, fixed

README §16 no longer documents the removed legacy flat-payload path or the
`isEncrypted` content decryption; §24 documents `receivedAt` and marks
`isEncrypted` as a legacy display flag; §26 no longer lists the media
permissions the manifest deliberately omits (audit M-7).

## Known gaps, recorded

- The `FLAG_SECURE` check is asserted by a source-text test rather than a
  behavior test (pre-existing, unchanged).
- LAN subnet learning is now exercised end-to-end through the announcement
  pipeline in `lan_route_pinning_test.dart` (the previous test used the
  `debugAllowSubnet` shortcut).
- Announcement freshness still admits same-window replays to *discovery*
  presence from the pinned-address host itself; route takeover is the
  security-relevant path and is now pinned.

## Validation

`flutter analyze` clean; every one of the 42 test files passes — the prior 139 tests plus the 26 new tests added with the fixes above (165 total) on Flutter 3.47.9 / Dart 3.13.7.

---

# Eighth Review (external reconciliation)

Input: an external review of the round-7 tree. Each finding was verified
against the source; severity was re-graded where the reviewer lacked code
context. Four findings were real and are fixed; two were refuted; two were
accepted as recorded limitations.

## Fixed

| # | Sev | Finding | Fix |
|---|-----|---------|-----|
| 1 | Med | `ProfileService` carried a latent plaintext write path: `updateAvatar` and `saveProfile` stored unencrypted bytes when the at-rest crypto was null. Production wiring always passes it, but the branch would silently activate on a wiring change, contradicting spec §10 | The `LocalDataCrypto` constructor parameter is now required (all 12 construction sites already pass it) and every `crypto == null` branch is gone. Legacy plaintext rows remain readable only through the documented migration path |
| 2 | Med-High | Per-peer throttles are rotation-defeatable: an attacker rotating UUIDs bypasses the 2-second identity throttle, buying unbounded RSA verify work and one signed reply per fresh UUID | Identity processing now runs under a global budget (20 per 10-second window, `AhoyConstants`), applied before verification, replies, and the per-peer throttle maps. Excess identities are dropped per §6.5. Test: `identity_budget_test.dart` (50 rotated UUIDs → exactly one window processed) |
| 3 | Med | A replay that survived the seen-set (eviction or restart) re-incremented `unreadCount` and moved `lastMessage*`, even though the store deduplicated the row | `MessageStore.addMessage` now returns whether the row was newly added; the conversation update runs only for genuinely new messages. A replay is now state-neutral: the residual cost is one redundant verification plus an idempotent ack. The replay-resilience test asserts the counter no longer moves. Spec §7 updated; OPEN #3 now covers only the redundant work |
| 4 | Med | BLE scan responses feed MAC-keyed announcements through `TransportManager._acceptAnnouncement` into `_peerTransports`, whose single 512-entry FIFO could be churned by ambient BLE devices — evicting real peers' routing entries (no attacker required; `putIfAbsent` does not refresh insertion order) | Routing tables split: verified-UUID entries keep the 512 cap; temporary transport ids live in their own 128-entry table. Alias registration merges temp entries into the real table; `currentModeFor` consults both. Tests: `transport_table_bounds_test.dart` |
| 5 | Low | The attached blocked set and the per-call inbound set are two handles to the same live set; drift was possible if a future caller forgot `attachBlockedPeers` | `onInboundPacket` now checks both. No behavior change; drift closed |

## Refuted with evidence

- None of the reviewer's remaining claims survived: finding 5 (announcement
  dedup flush) requires a valid signing key and, even after a flush, route
  pinning (§3.1 rule 7) blocks same-window takeover — the residual is
  discovery presence refresh, already recorded in round 7. Finding 7 was
  self-refuted by the reviewer: the subnet prefix check appends a dot and
  fails closed on a malformed group-owner address.

## Accepted, recorded

- Replay after seen-set eviction remains possible (spec §7 known limit,
  OPEN #3) but is now state-neutral; the persisted, conversation-keyed
  replay set stays a user decision.

## Validation

`flutter analyze` clean; all affected and new tests green (see the run log
for the count).
