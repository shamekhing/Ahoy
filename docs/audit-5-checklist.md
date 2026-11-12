# Fifth Review Checklist

Branch `audit/fifth-review`, one commit per step. Each commit ticks its box
here. Findings merge the internal audit and the external static review.

## Setup

- [ ] 0a `chore: normalize punctuation in docs and comments` (pre-existing tree)
- [ ] 0b `docs: add the fifth review checklist` (this file)

## Phase 1: broken feature and broken promise

- [ ] 1 `fix(chat): send voice message bytes instead of the deleted temp path (audit H-1)`
      voice payload built from bytes read once; `_encodeMediaContent` throws;
      inbound empty media dropped; outbox carries bytes, not a dead path
- [ ] 2 `fix(discovery): enforce Off the Grid in the transport manager (audit H-3)`
      `_offGrid` flag in `TransportManager`, gates on start, refresh, profile edit
- [ ] 3 `fix(chat): serialize store writes across lock handoff (audit M-3)`
      ownership handoff in `ConversationStore` and `MessageStore` locks
- [ ] 4 `fix(auth): require confirmation before replacing an existing identity (audit M-2)`
      `signUp` guard plus explicit erase-and-replace confirmation

## Phase 2: one trust store

- [ ] 5 `feat(trust): add a single monotonic peer key store (audit H-2)`
      `PeerTrustStore` (unverified/pinned/verifiedBySafetyNumber), first key
      wins, conflicting keys recorded as pending, never applied
- [ ] 6 `fix(transport): bind WiFi Direct routing to the first verified key (audit H-2)`
      second identity for a known UUID cannot repoint the route
- [ ] 7 `feat(ui): show peer trust state and key-change warnings (audit H-2)`
      unverified badge, key-change banner, safety-number promotion,
      shortId labelled display-only

## Phase 3: data lifecycle and privacy

- [ ] 8 `fix(storage): bind the iOS at-rest key to the device and recover from undecryptable data (audit M-1)`
      `first_unlock_this_device`, quarantine undecryptable records,
      startup recovery instead of a dead error screen
- [ ] 9 `fix(privacy): gate identity exchanges on Receive Off and stop auto-connecting to unknown P2P devices (audit M-4)`
- [ ] 10 `fix(media): remove plaintext picker copies and move encoding off the UI isolate (audit M-5)`
- [ ] 11 `fix(chat): fail orphaned sends at startup instead of stranding them (audit M-6)`
- [ ] 12 `fix(android): narrow permissions and request location only where required (audit M-7)`

## Phase 4: hardening, low items, docs

- [ ] 13 `fix(security): bound session state and rate-limit inbound frames (audit M-8, L-13)`
- [ ] 14 `fix(chat): delete conversation media with the conversation (audit L-1)`
- [ ] 15 `fix(chat): drop the legacy plaintext inbound path (audit L-2)`
- [ ] 16 `fix(ble): key chunk assemblies by peer and message id (audit L-3)`
- [ ] 17 `fix(crypto): cap untrusted PEM and iteration inputs (audit L-4)`
- [ ] 18 `fix(discovery): keyless announcements cannot rename key-verified peers (audit L-5)`
- [ ] 19 `fix(ui): require authentication to enable biometrics and block screenshots (audit L-6)`
- [ ] 20 `fix(profile): propagate renames to outgoing payloads (audit L-7)`
- [ ] 21 `docs(crypto): record PKCS#1 v1.5, AAD and double-verification decisions (audit L-8)`
- [ ] 22 `fix(ble): encode names correctly and release idle connections (audit L-9)`
- [ ] 23 `fix(storage): skip local data migration once completed (audit L-10)`
- [ ] 24 `chore(build): enable R8 with keep rules and refresh deprecated options (audit L-11)`
- [ ] 25 `docs: fifth review section, README drift, accepted risks (audit L-11, L-12)`
      AUDIT.md fifth review, README drift fixes, accepted-risk entries
      (password policy, background lifecycle), all boxes above ticked

## Gates

Per commit: `flutter analyze` clean, targeted test green, only that step's
files staged. Full `flutter test` after commits 4, 7, 13, 20 and 25.
