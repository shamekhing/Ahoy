# Fifth Review Checklist

Branch `audit/fifth-review`, one commit per step. Each commit ticks its box
here. IDs follow the fifth review (`AUDIT.md`, "Fifth External Review").
Findings H-1 to H-3, M-1 to M-10 and L-1 to L-16 are the fifth review's own
numbers. The first internal audit items are referenced by their original
labels in parentheses where they differ.

## Setup

- [ ] 0a `chore: normalize punctuation in docs and comments` (pre-existing tree)
- [ ] 0b `docs: add the fifth review checklist` (this file)

## Phase 1: broken feature and broken promise

- [ ] 1 `fix(chat): send voice message bytes instead of the deleted temp path (H-1)`
      Read voice bytes once before any storage step. `_encodeMediaContent`
      throws on a missing file instead of returning `''`. Inbound empty media
      is dropped. The keyless outbox carries bytes, not a dead path.
      Tests: voice send round-trip delivers non-empty audio; send with a
      missing source file fails loudly; keyless outbox retry still delivers
      the audio.
- [ ] 2 `fix(discovery): enforce Off the Grid in the transport manager (first audit #3)`
      `_offGrid` moves into `TransportManager`. Gates `startAdvertising` and
      `_broadcast`, and the start, refresh and profile-edit paths all go
      through the gate.
      Tests: Off the Grid survives restart; `refreshPeers` does not
      re-advertise; profile edit does not re-advertise while off.
- [ ] 3 `fix(chat): serialize store writes across lock handoff (M-6)`
      Lock ownership passes directly to the next waiter in `ConversationStore`
      and `MessageStore`; `_locked` is never cleared while a waiter is queued.
      Tests: concurrent `mutateOrCreate` and `addMessage` calls keep both
      updates; no caller enters between release and wake-up.
- [ ] 4 `fix(auth): require confirmation before replacing an existing identity (M-4)`
      `signUp` refuses when an account exists. The explicit
      erase-and-replace path requires confirmation.
      Tests: sign-up with an existing account is refused without
      confirmation; confirmed replacement clears the old identity.

## Phase 2: one trust store

- [ ] 5 `feat(trust): add a single monotonic peer key store (H-2, H-3)`
      `PeerTrustStore` with states unverified, pinned, and
      verifiedBySafetyNumber. First key wins. Conflicting keys are recorded
      as pending and never applied. `ChatService.registerVerifiedPeerKey` and
      `DiscoveryService` both read from this store. In
      `DiscoveryProvider.onAnnouncement`, `onVerifiedKey` fires only after
      discovery accepts the announcement.
      Tests: forged self-signed announcement cannot replace a known key;
      announcement order does not change the result; conflicting key is
      recorded as pending.
- [ ] 6 `fix(transport): bind WiFi Direct routing to the first verified key (H-3)`
      The first verified identity for a UUID fixes its route. A later identity
      for the same UUID with a different key or a different route is ignored.
      Tests: second identity for a known UUID cannot repoint the route;
      routing survives a forged identity from another group member.
- [ ] 7 `feat(ui): show peer trust state and key-change warnings (H-2, H-3)`
      Unverified badge on peer cards and profile. Key-change banner in
      `PeerProfileScreen`. Safety-number comparison promotes a peer to
      verifiedBySafetyNumber. shortId is labelled display-only.
      Tests: identity with a different pinned key gets no reply and raises
      the banner state; safety-number match promotes trust state.

## Phase 3: data lifecycle and privacy

- [ ] 8 `fix(storage): bind the iOS at-rest key to the device and recover from undecryptable data (M-1, M-9)`
      `IOSOptions(accessibility: first_unlock_this_device)`, with a one-time
      rewrite of existing Keychain items on load. Undecryptable profile,
      conversation, message and media records are quarantined (renamed) and
      treated as empty, with a one-time notice. Startup recovers instead of
      showing the dead error screen. Keychain-survives-reinstall case: a
      marker in prefs detects a reinstall and clears the stale Keychain
      identity, so the user sees sign-up instead of "Profile data missing".
      Tests: undecryptable prefs start clean; quarantined records are renamed,
      not deleted; reinstall marker triggers a clean sign-in state.
- [ ] 9 `fix(privacy): gate identity exchanges on Receive Off and stop auto-connecting to unknown P2P devices (M-10, M-4 in first audit)`
      Identity handling and the identity reply are skipped under Receive Off
      unless the peer already has a conversation. WiFi Direct auto-connect is
      limited to known Ahoy peers.
      Tests: receive-off drops identity probes with no reply; unknown WiFi
      Direct devices are not auto-connected.
- [ ] 10 `fix(media): remove plaintext picker copies, move encoding off the UI isolate, cap inbound media (M-5 first audit, L-11)`
      Picker output is deleted after encryption. Sign-out clears the temp
      directory. Base64 encoding runs in an isolate. Inbound media has a
      per-file size cap and a total disk quota; oversized or over-quota media
      is rejected with a visible error.
      Tests: picker copy is gone after send; oversized inbound media is
      rejected; quota refusal leaves existing media intact.
- [ ] 11 `fix(chat): fail orphaned sends at startup instead of stranding them (M-8 first audit)`
      The keyless outbox is persisted. On startup, any message still in
      `sending` with no live queue entry is marked failed, and queued media
      whose source is gone is marked failed.
      Tests: restart marks orphaned `sending` messages failed; persisted
      outbox entry survives restart and retries on peer return.
- [ ] 12 `fix(android): narrow permissions and resolve identifier exposure (M-7)`
      Remove READ_MEDIA_IMAGES, READ_MEDIA_AUDIO and READ_EXTERNAL_STORAGE if
      the photo picker and temp recording do not need them. Add
      `neverForLocation` to BLUETOOTH_SCAN and drop ACCESS_FINE_LOCATION where
      not required. For the broadcast identifiers, the step either removes the
      public key from UDP announcements (fetched on demand over TCP) or
      records the decision as an accepted risk in step 25.
      Tests: manifest test asserts the narrowed permission set.

## Phase 4: hardening, low items, docs

- [ ] 13 `fix(security): bound session state, rate-limit inbound frames, and cap media (M-8 fifth, L-9)`
      LRU caps on `_verifiedKeys`, `_identitySentAt`, `_identityRepliedTo`,
      `_shortIdToUuid`, `_peerAliases` and `_peerTransports`. Per-peer rate
      limit on identity and handshake frames. LAN TCP connection cap. RSA
      verification is rate-limited per source address.
      Tests: map sizes stay bounded under forged UUID flood; excess frames are
      dropped.
- [ ] 14 `fix(chat): delete conversation media with the conversation (L-8)`
      `deleteConversation` removes owned `ahoy_media_*` files along with the
      prefs key.
      Tests: deleting a conversation removes its media files and leaves other
      conversations' files intact.
- [ ] 15 `fix(chat): drop the legacy plaintext inbound path (M-11, L-10)`
      Unsealed, versionless messages are rejected. Earlier builds are not
      supported for receive; the decision is recorded in step 25.
      Tests: plaintext inbound from a pinned peer is rejected.
- [ ] 16 `fix(ble): key chunk assemblies by peer and message id (first audit Low)`
      Message IDs become UUIDs. Assemblies are keyed by peer address and
      message ID, so same-millisecond sends cannot collide.
      Tests: two concurrent assemblies with identical timestamps reassemble
      independently.
- [ ] 17 `fix(crypto): cap untrusted PEM and iteration inputs (L-12)`
      Peer PEM length is capped before parsing. Stored PBKDF2 iteration count
      has an upper bound.
      Tests: oversized PEM is rejected without parsing; out-of-range iteration
      count fails verification.
- [ ] 18 `fix(discovery): keyless announcements cannot rename key-verified peers (L-13)`
      The shortId-based absorb does not overwrite the display name of a
      key-verified canonical record.
      Tests: keyless BLE announcement with a matching shortId keeps the
      verified display name.
- [ ] 19 `fix(ui): require authentication to enable biometrics and block screenshots (L-14, L-16)`
      `enableBiometric` runs a successful `authenticate()` first. `FLAG_SECURE`
      is set on Android.
      Tests: enabling biometrics without successful auth leaves the flag off.
- [ ] 20 `fix(profile): propagate renames to outgoing payloads (L-15)`
      A profile rename updates `ChatService`'s sender identity and
      re-advertises.
      Tests: payload after rename carries the new display name.
- [ ] 21 `docs(crypto): record PKCS#1 v1.5, AAD and double-verification decisions (L-1 to L-7)`
      Accepted-hardening entries for PKCS#1 v1.5 signatures, missing AAD in
      the GCM envelope, and double verification of LAN and WiFi Direct
      announcements, each with the reason it is not a break.
- [ ] 22 `fix(ble): encode names correctly and release idle connections (first audit Low)`
      Display names are encoded as UTF-8 within the 13-byte budget. Idle GATT
      connections are released after a timeout.
      Tests: non-ASCII name survives the scan-response budget without
      corruption; idle connection is released.
- [ ] 23 `fix(storage): skip local data migration once completed (first audit Low)`
      A completion marker stops the migrator decrypting everything on each
      launch.
      Tests: second launch does not re-run migration.
- [ ] 24 `chore(build): enable R8 with keep rules and refresh deprecated options (first audit Low)`
      R8 enabled with keep rules for the crypto and reflection paths.
      `encryptedSharedPreferences` deprecation checked against the current
      plugin version.
      Tests: release build assembles; crypto round-trip passes in a release
      build.
- [ ] 25 `docs: fifth review section, README drift, accepted risks (all remaining)`
      `AUDIT.md` gets a "Fifth External Review" section in the existing
      format. README drift is fixed (`discovery_controls.dart`,
      `_maybeStartTransports`, `Navigator.pushNamed`, the `AuthService`
      constructor, and the unused `ahoy_router.dart`). Accepted-risk entries
      cover: the write-amplification cost of re-encrypting conversation
      history per write; the GATT characteristic writable by nearby devices;
      iOS having no BLE advertising or GATT server (scope decision); the
      password policy (minimum 8 characters, no change-password flow); the
      WiFi Direct background lifecycle; and any identifier-broadcast decision
      from step 12. All boxes above ticked.

## Gates

Per commit: `flutter analyze` clean, targeted test green, only that step's
files staged. Full `flutter test` after commits 4, 7, 13, 20 and 25.