# Ahoy Protocol Specification

Status: Draft v1, derived from the current implementation.
Scope: identity, discovery, message envelopes, signatures, encryption, freshness, key pinning, and transport framing.
Anything marked **OPEN** is an unresolved decision. Anything marked **CODE MISMATCH** is behavior the code does today that this spec does not endorse yet.

This document is normative. If the code and this document disagree, the code is wrong unless a decision record says otherwise.

---

## 1. Goals and threat model

Ahoy is a serverless messenger for nearby devices. Peers reach each other over WiFi Direct, LAN (UDP broadcast plus TCP), or BLE.

**Assumed adversary:** any device within radio range or on the same LAN segment. The adversary can observe all traffic, inject packets, replay captured packets, forge UDP announcements, claim any displayed name or short ID, and run its own Ahoy identity.

**Protected properties:**
- Confidentiality of message content and sender metadata (names, short IDs, message IDs, timestamps) against passive observers and transport-level observers.
- Sender authenticity: a message is attributed to the key that signed it.
- Integrity of content and of the signed fields.
- Replay resistance within a freshness window.
- Identity binding: a UUID is bound to one public key for the lifetime of a conversation, and key changes are surfaced, never applied silently.

**Not protected:**
- Metadata visible on the wire, which is limited to the routing UUID, the transport, and the packet size (see §9).
- Device compromise. Keys in secure storage are only as safe as the device.
- Availability. An adversary can always jam radio or flood the LAN.
- Forward secrecy. Keys are long-lived RSA identity keys; there is no ratcheting. **OPEN** (see §12).
- Deniability. Messages are signed, so authorship is provable to a third party.

---

## 2. Identities

Each installation holds one identity.

| Field | Definition |
|---|---|
| `uuid` | UUID v4, generated at sign-up. Canonical identity. Must match `^[0-9a-fA-F]{8}-…-[0-9a-fA-F]{12}$`. |
| `shortId` | `shortIdFromUuid(uuid)`: take `SHA-256(uuid)`, use the first 12 hex characters as an integer, convert to base-36, left-pad to 6 with `0`, take the first 6, uppercase. Display only. |
| `publicKeyPEM` | RSA-2048, public exponent 65537, PEM `RSA PUBLIC KEY` (PKCS#1). |
| `privateKeyPEM` | RSA-2048 matching key, PEM `RSA PRIVATE KEY`. Never leaves secure storage. |

`shortId` is derived from `uuid`, so it cannot be chosen freely. Any announcement whose `shortId` does not match its `uuid` is invalid.

Temporary transport identifiers (Bluetooth MAC addresses, WiFi Direct device addresses) are **not** Ahoy identities. They are valid only as routing hints until the peer's real `uuid` is learned from a verified announcement or identity message.

---

## 3. Discovery

Discovery announces an identity. It carries no secrets. It is sent unencrypted and is public to anyone listening.

### 3.1 Announcement (LAN UDP and WiFi Direct identity)

Sent on UDP port 45678 (LAN) every 5 seconds, to `255.255.255.255` and to each interface's `x.y.z.255`.

Fields:

```
type          "ahoy_announce"           (LAN only)
uuid          string
shortId       string
displayName   string
statusMessage string | null
publicKeyPEM  string
timestamp     ISO-8601 UTC string
signature     base64(RSA-PKCS1v1.5-SHA256(material))
```

**Signed material (frozen):**

```
"ahoy-announce-v1:" + JSON({
  "uuid", "shortId", "displayName", "statusMessage",
  "publicKeyPEM", "timestamp"
})
```

JSON is the canonical encoding produced by `jsonEncode` with keys in the listed order. `statusMessage` is `null` when absent.

**Acceptance rules (all must hold):**
1. `uuid` matches the UUID pattern. Non-UUID identifiers are not accepted on LAN or WiFi Direct.
2. `shortId` equals `shortIdFromUuid(uuid)` when non-empty.
3. `publicKeyPEM` is present, at most 4096 bytes, and parses as RSA.
4. `signature` verifies over the material with `publicKeyPEM`.
5. `timestamp` is within **15 minutes** of local time, in either direction.
6. If this `uuid` already has a known key, the new key must equal it (whitespace-insensitive). A different key is dropped before any routing state changes.

7. **Route pinning:** a verified announcement repoints the LAN TCP route only when no route exists for the `uuid`, when it comes from the already-pinned address, or when the pinned address has not announced itself for more than the 30-second peer-expiry window. A captured announcement replayed from a different address within the freshness window cannot take over a live peer's route.

8. **Announcement replay cache:** the pair `(uuid, signature)` is remembered in a bounded set (1024 entries, FIFO). An announcement whose pair is already present is dropped before signature verification, so replays never reach the crypto layer.

9. **Announcement rate limit:** announcements from one address are processed at most 20 per 10-second window; excess datagrams are dropped before any parsing or verification. Loopback is exempt, matching the TCP carve-out.

Packets from outside the device's own interface subnets are dropped. Loopback is accepted.

The per-transport route and known-key maps are bounded at 512 entries each (expired routes drop first, then the oldest), so a flood of unique valid announcements cannot grow transport memory without bound (§8).

### 3.2 BLE scan response

The BLE advertisement has a 13-byte budget and cannot carry a signature. Format:

```
shortId[0:6] (ASCII) | 0x00 | displayName UTF-8, truncated to 6 bytes on a character boundary
```

BLE announcements are display-only. They carry a MAC address as the `uuid`, and they never create trusted key bindings or rename a peer whose key is already verified. Identity is bound later, at the first signed identity exchange (§6.3).

---

## 4. Key trust

Each peer UUID has one trust record: `{ key, state, pendingKey }`.

**States:**
- `unverified`: the key was learned from a verified announcement or identity message.
- `pinned`: the peer has signed an accepted chat message with this key.
- `verifiedBySafetyNumber`: the user compared safety numbers out of band.

**Rules:**
1. The first key observed for a UUID wins. It becomes `key` in state `unverified`.
2. A different key for the same UUID is stored as `pendingKey` and is never used for sealing or verification.
3. Moving from `unverified` to `pinned` requires a successfully verified signed chat message from that key.
4. `verifiedBySafetyNumber` is set only by the user. The UI must show the key-change warning until the user resolves `pendingKey` by either accepting the safety-number check or dismissing the change.
5. A conversation pins `peerPublicKeyPEM` on first accepted message. Once pinned, the conversation key never changes automatically. A candidate key that differs is ignored and logged.
6. Trust records are capped at 256 entries. Eviction removes `unverified` records first, then `pinned` records; a `verifiedBySafetyNumber` record is evicted only as a last resort, so an out-of-band verification is never silently lost to an announcement flood.

**Safety numbers.** For a conversation between keys `A` and `B`:

```
canonical(X) = PEM with all whitespace removed
sorted = sort([canonical(A), canonical(B)])
digest = SHA-256("ahoy-safety-v1:" + sorted[0] + "|" + sorted[1])
number = 12 groups of 5 decimal digits, each group = 17-bit slice of digest[0:51 hex] mod 100000
```

Both peers compute the same 60 digits. Comparing them out of band confirms the keys.

---

## 5. Message envelope

All chat, ack, and identity traffic travels in one of these envelopes. The routing UUID is the only field outside the encrypted blob.

### 5.1 Sealed envelope (version 3)

```json
{ "v": 3, "ct": "<base64 of sealed envelope v2>", "from": "<sender uuid>" }
```

`from` is the routing UUID. It is not authenticated by the envelope. The inner signature (§5.3) binds the sender identity, and the receiver rejects a message whose inner `senderUuid` differs from the routing `from`.

### 5.2 Sealing (hybrid encryption)

Sealing uses RSA-OAEP-SHA-256 to wrap a per-message AES-256 key, and AES-256-GCM for the payload.

```
aesKey  = random(32)
iv      = random(12)
ct      = AES-256-GCM(aesKey, iv, plaintext)            (no AAD, see §5.5)
ek      = RSA-OAEP-SHA256(recipientPublicKey, aesKey)
sealed  = base64( utf8( JSON({ "v": 2, "ek": base64(ek), "iv": base64(iv), "ct": base64(ct) }) ) )
```

The receiver checks `v == 2`, unwraps `aesKey` with its private key, and decrypts with GCM. An authentication failure drops the message.

### 5.3 Inner chat payload (v3 inner)

Plaintext of `ct` for a chat message:

```
msgType         "chat"
msgId           UUID-like token, 1–64 characters, [0-9a-fA-F-]
convId          conversationId(myUuid, peerUuid)  (see §5.6)
senderUuid      sender UUID
senderShortId   sender shortId
senderName      sender display name
type            "text" | "image" | "voice"
content         text, or base64 of the media bytes
replyToId       string | null
replyToPreview  string | null
timestamp       ISO-8601 UTC
senderPublicKeyPEM  sender public key
signature       base64(RSA-PKCS1v1.5-SHA256(material))
```

**Signed material (frozen):**

```
"ahoy-chat-v3:" + JSON({
  msgType, msgId, convId, senderUuid, senderShortId, senderName,
  type, content, replyToId, replyToPreview, timestamp, senderPublicKeyPEM
})
```

The signature covers every field above except `signature` itself. Changing any field invalidates the message.

### 5.4 Inner acknowledgment

```
msgType     "ack"
ackFor      msgId being acknowledged
convId      conversationId
senderUuid  acknowledging peer's UUID
timestamp   ISO-8601 UTC
signature   base64(RSA-PKCS1v1.5-SHA256("ahoy-ack-v1:" + JSON({msgType, ackFor, convId, senderUuid, timestamp})))
```

Acks are sealed to the pinned conversation key, the same way chat messages are.

An ack is accepted only if all of the following hold:
1. `convId` equals the conversation derived from the local and routing UUIDs.
2. Inner `senderUuid` equals the routing peer UUID.
3. `timestamp` is within the freshness window.
4. `ackFor` names a message stored locally as outgoing, in state `sent`. An ack for an unknown message, a `failed` message, or a message already `delivered` changes nothing.
5. The signature verifies with the pinned conversation key.

Only a valid ack moves a message to `delivered`. Replayed acks therefore cannot upgrade anything.

### 5.5 Associated data

AES-GCM is used with no AAD. The security argument is that every metadata field lives inside the sealed plaintext and is covered by the inner signature, so AAD would duplicate a guarantee that already exists. Routing metadata outside the envelope is limited to `v` and `from`. `from` is unauthenticated. A receiver never trusts it on its own; it is accepted only when it equals the inner `senderUuid`, which is covered by the inner signature. An attacker who swaps `from` therefore cannot make a message appear to come from another peer, but can cause a valid message to be dropped.

**OPEN:** if the routing `from` field becomes security-relevant (for example, a replayed envelope with a swapped `from`), AAD should bind `v` and `from`. Today the inner `senderUuid` check covers this.

### 5.6 Conversation identifier

```
convId = hex( SHA-256( min(uuidA, uuidB) + ":" + max(uuidA, uuidB) ) )[0:32]
```

Both peers derive the same `convId` regardless of who initiates.

---

## 6. Identity exchange and first contact

Identity messages are unsealed, because they bootstrap the key relationship. They carry no content.

### 6.1 Identity message

Identity packets travel with the same unauthenticated routing `from` field that sealed envelopes use (added by the transport layer, see §5.1); over BLE the assembled packet's `from` is what the receiver treats as the routing identity. Acceptance rule 1 binds it.

```
msgType        "identity"
senderUuid     string
senderShortId  string
senderName     string
senderPublicKeyPEM  string
timestamp      ISO-8601 UTC
signature      base64(RSA-PKCS1v1.5-SHA256("ahoy-identity-v1:" + JSON({msgType, senderUuid, senderShortId, senderName, senderPublicKeyPEM, timestamp})))
```

**Acceptance:**
1. `senderUuid` must equal the routing `from` value (spoof guard).
2. `timestamp` is within 15 minutes.
3. The signature verifies with `senderPublicKeyPEM`.
4. If a key is already known for `senderUuid`, the new key must match. A conflicting identity is dropped before any reply, retry, or state change.

An accepted identity registers the key as `unverified`. It is answered once with the local identity, and the reply is not answered in turn. It may also release queued messages.

**Throttling:** identity messages from one peer are processed at most once every 2 seconds. Identity replies are rate-limited per peer, at most once every 10 seconds. In addition, identity processing runs under a **global budget** of 20 messages per 10-second window, applied before verification, replies, and the per-peer throttle maps: rotating UUIDs cannot purchase more RSA work than the budget allows, and excess identities are dropped (§6.5).

### 6.2 Receive Off

When Receive Off is on, identity messages are ignored unless a conversation with that peer already exists. This stops strangers from probing presence.

### 6.3 Keyless first contact

A peer seen only over BLE has no key. A sender with no verified recipient key does not send plaintext. It:
1. Sends its own signed identity to the peer.
2. Queues the message in the outbox.
3. Sends the sealed message once the peer's identity arrives and verifies.

Content never leaves the device without a verified recipient key.

**Rebinding to the canonical identity.** The first contact is keyed by the temporary transport id (the Bluetooth MAC). When a signed payload — the peer's identity or first sealed message — proves the canonical UUID, the transport binds the temporary id to it (§8) and the conversation, its messages and the outbox entries are re-keyed to the canonical UUID, so replies, acknowledgments and retries agree with the wire `convId` both sides derive from the real UUIDs.

### 6.4 Pinning on first message

For a new conversation, an inbound chat message is accepted only if:
- its signature verifies against the sender key, and
- if a discovery-verified key exists for this UUID, the sender key matches it.

A first message from an impostor who presents a different key fails the second check and is dropped.

---

### 6.5 Failure behavior

"Drop" in this document means: the packet produces no reply, no retry, no state change, no stored message, and no trust-record change. The only outward effect is a local diagnostic log. No user-visible error is shown, except where a send-side failure is already reported by the UI (for example, a failed send marks the message `failed`). Receivers never report verification failures to the sender.

## 7. Freshness and replay

| Object | Window |
|---|---|
| Announcement timestamp | ±15 minutes |
| Chat message timestamp | ±15 minutes |
| Identity timestamp | ±15 minutes |
| Ack timestamp | ±15 minutes |

Within the window, replay is blocked by a bounded seen-set of `msgId` values (512 entries, FIFO). Only authenticated messages enter the set, so unauthenticated garbage cannot evict real entries.

**Known limit:** a replay within the window is dropped only if the message ID is still in the seen-set. A replay after eviction (or after a restart, which clears the set) still costs one signature verification, one decryption, and an idempotent re-ack, but it changes no persistent state: the store deduplicates by message id, and the conversation's unread counter and last-message fields move only for messages that were actually added. Persisting the set keyed by `(convId, msgId)` remains open (**OPEN** §12) to save the redundant work itself.

Clock skew of more than 15 minutes between devices causes rejections. There is no time synchronization. This is a known usability cost.

---

## 8. Transport framing

**Routing tables.** Verified Ahoy-UUID routing entries are capped at 512. Temporary transport identifiers (Bluetooth MACs, WiFi Direct addresses) are capped at 128 in their own table, so ambient discoverable devices cannot churn real peers out of the verified-UUID table. Alias registration merges a temporary entry into the verified table. Each transport also keeps its own bounded route and known-key maps (512 entries each, §3.1); the BLE scan cache is capped at 256 devices.

### 8.1 LAN (TCP, port 45679)

- Messages are newline-delimited JSON. Each message is one envelope, terminated by `\n`.
- Maximum payload: 16 MiB per message.
- Maximum 8 messages per TCP connection. The connection then closes.
- Maximum 32 concurrent inbound connections.
- Maximum 20 messages per remote address per 10-second window.
- Idle timeout: 10 seconds.
- Absolute connection lifetime: 60 seconds, regardless of activity (the idle timeout alone is attacker defeatable because every received byte resets it).
- Aggregate inbound buffer budget: 64 MiB across all connections, so unterminated messages cannot allocate `maxConnections × maxPayload` at once.
- Accepted only from /24 subnets that have announced themselves, or from loopback.
- The announced port is never trusted. The messaging port is fixed at 45679 on both ends.

### 8.2 WiFi Direct (TCP, port 8765)

- Framing is a 4-byte big-endian length followed by the payload.
- Maximum payload: 10 MiB.
- Accepted only from the group's /24 subnet, which is derived from the group owner's address. If the subnet is unknown, all inbound connections are refused.
- Routes are learned only from verified WiFi Direct identity packets.
- The first verified key for a UUID is kept for the process lifetime. A later identity for the same UUID with a different key is refused. This key binding is cleared on sign-out only; teardown of the group does not clear it (accepted, see §13).

### 8.3 BLE (GATT)

- Service UUID: `12345678-1234-1234-1234-123456789abc`
- Characteristic UUID: `12345678-1234-1234-1234-123456789def`, read and write.
- Each write is a JSON chunk envelope `{ m, seq, total, data }`, where `data` is base64 of up to 180 bytes.
- Maximum payload: 256 KiB, at most 16 concurrent reassembly buffers.
- Reassembly is keyed by `(deviceAddress, m)`. Incomplete assemblies are evicted after 60 seconds.
- Media (image, voice) is not sent over BLE.

---

## 9. What is visible on the wire

| Transport | Visible to a passive observer |
|---|---|
| LAN UDP announcement | `uuid`, `shortId`, `displayName`, `statusMessage`, `publicKeyPEM`, `signature`, `timestamp`. **All public.** |
| LAN TCP | `from` (UUID), envelope size, timing. Identity packets (§6.1) are unsealed, so their full field set is visible here and over WiFi Direct. |
| WiFi Direct TCP | Length prefix, `senderIP`, timing |
| BLE advertisement | `shortId`, display name (first 6 bytes) |
| BLE GATT | Chunk sizes, sequence, `m` identifier |

**Consequence:** the discovery layer is not private. Anyone nearby learns the display name and UUID of every Ahoy device, and can link them to a stable key. Message content and the sender's identity fields inside messages are not visible. This is a deliberate trade-off, since discovery must work before any key exchange.

**OPEN:** whether `displayName` and `statusMessage` should be encrypted for trusted peers, or hashed, or dropped from the broadcast. Decide before first release.

---

## 10. Storage

| Item | Location | Protection |
|---|---|---|
| Private key, public key | secure store | Keychain / EncryptedSharedPreferences, device-bound on iOS |
| Password hash | secure store | PBKDF2-HMAC-SHA256, 310,000 iterations, 16-byte salt |
| Local data key | secure store | random AES-256, used for encrypted prefs and media |
| Profile, conversations, messages | prefs | AES-256-GCM via local data key, prefix `ahoyenc:v1:` |
| Media files | app documents | AES-256-GCM via local data key, extension `.ahoyenc`, excluded from backup |
| Outbox | prefs | encrypted, media bytes not persisted |

Undecryptable local data is quarantined, not thrown. Sign-out erases all of the above and resets the local data key.

---

## 11. Versioning

- Envelope version `v` is currently `3` for chat and ack, and `2` is the inner RSA-OAEP/GCM wrapper.
- Signed material prefixes (`ahoy-announce-v1`, `ahoy-chat-v3`, `ahoy-ack-v1`, `ahoy-identity-v1`, `ahoy-safety-v1`) are version tags. Changing any signed field set requires a new prefix.
- A receiver rejects unknown envelope versions. It does not guess.

**Compatibility rule:** until the first public release, the wire format may change freely, but each change must be recorded in §13. After release, changes require a new envelope version and a migration path.

---

## 12. Open decisions

Each item needs a decision before the protocol is frozen.

1. **Signature padding.** PKCS#1 v1.5 is used throughout. RSA-PSS would be the modern choice. Changing it is a breaking change, so it must be decided now or deferred to a new protocol version.
2. **AAD binding.** Currently none. Decide whether `v` and routing `from` should be bound (§5.5).
3. **Replay set scope.** Keying the seen-set by `(convId, msgId)` and enlarging it (§7).
4. **Forward secrecy.** Ratcheting would be a large change. Decide whether it is in scope for v1 or explicitly out.
5. **Discovery privacy.** Whether `displayName` and `statusMessage` are broadcast in clear (§9).
6. **Key-binding persistence.** Whether WiFi Direct and LAN key bindings should survive process restart. Currently only conversation pins persist.
7. **Clock dependence.** Whether to add a relative clock check, for example a challenge-response on first contact, to remove the ±15-minute dependency.

---

## 13. Change log

| Date | Change | Reason |
|---|---|---|
| — | Initial draft derived from implementation | Establish a single reference |
| 2026-11-12 | §3.1 rules 7–8 added: LAN route pinning and the bounded `(uuid, signature)` announcement replay cache | Round-7 review: a same-key announcement replayed from a neighbouring address repointed the routing of a live peer |
| 2026-11-12 | §4 rule 6 refined: eviction prefers unverified, then pinned; safety-number-verified records evicted last | Round-7 review: flood pressure could silently drop an out-of-band verification |
| 2026-11-12 | §8.1: absolute connection lifetime (60 s) and aggregate inbound buffer budget (64 MiB) added to the LAN framing rules and Appendix A | Round-7 review: the idle timeout alone is attacker defeatable; 32 × 16 MiB of unterminated buffers was allocatable |
| 2026-11-12 | §6.1: documented that identity packets carry the routing `from` field; §9 LAN TCP row notes identity packets are visible in the clear | Spec gap: the code has always attached routing `from` to identity packets |
| 2026-11-12 | §8.2 CODE MISMATCH accepted: WiFi Direct key bindings are cleared on sign-out only, not on group teardown | Binding must survive group reformations within a session; asserted by `wifi_direct_binding_test.dart` |
| 2026-11-12 | Appendix B vectors generated from the reference implementation with the fixed fixture key `test/fixtures/ahoy_test_key.pem` | Release gate item 3 |
| 2026-11-12 | §14: replay-after-eviction, WiFi-Direct teardown binding, and sealed-envelope `from` swap now covered by tests | Release gate item 4 |
| 2026-11-12 | §10: `ProfileService` at-rest crypto is now a required constructor parameter; the latent plaintext profile/avatar write paths are removed | External review: the `crypto == null` branches would silently activate on a wiring change |
| 2026-11-12 | §6.1: identity processing is capped by a global budget (20 per 10 s) applied before verification and replies | External review: UUID rotation defeats per-peer throttles and buys unlimited RSA work |
| 2026-11-12 | §7: replays that survive the seen-set are state-neutral — the store dedup gates the unread counter and last-message fields | External review: a replayed message re-incremented `unreadCount` |
| 2026-11-12 | §8: routing tables split — verified UUIDs capped at 512, temporary transport ids capped at 128 in their own table | External review: ambient BLE devices could churn real peers out of the single shared table |
| 2026-11-12 | §3.1 rule 9 and §8: per-address UDP announcement rate limit (20 per 10 s) and bounded per-transport route/key maps (512 each); BLE scan cache capped at 256 | Ninth review: the LAN route and key maps and the WiFi Direct key map grew without bound under unique valid announcements, and UDP announcements had no rate limit |
| 2026-11-12 | §6.3 and §8: alias binding at packet receipt — sends, retry triggers and first-contact conversations rebind to the canonical UUID once a signed payload binds the temporary transport id to it; the BLE transport resolves the canonical UUID to the device address on send | Ninth review: a pure BLE first contact could never complete — the responder's sends and the initiator's retry were keyed under ids the BLE transport could not resolve |

Record every future change here, with the finding or decision that motivated it. A change to a signed field set must update §5, §6, or §3 as relevant, and must bump the prefix.

---

## 14. Test obligations

Every normative rule in this document must have at least one test. The existing suite covers most of them. The previously listed gaps are closed:

- Replay after seen-set eviction within the freshness window (§7) — `chat_replay_resilience_test.dart`, documents the known limit pending OPEN decision #3.
- WiFi Direct key binding after group teardown, which the code preserves (§8.2) — `wifi_direct_binding_test.dart`.
- Sealed-envelope `from` swap, which fails the inner `senderUuid` check (§5.1) — `chat_replay_resilience_test.dart`.

Appendix A is asserted against the code by `protocol_constants_parity_test.dart`; Appendix B vectors are asserted by `protocol_golden_vectors_test.dart`.

When a rule in this document changes, the corresponding test changes in the same commit.

---

## Appendix A. Constants

Every limit in this specification. The code must match these values. Changing one is a spec change and goes in §13.

| Constant | Value | Section |
|---|---|---|
| Timestamp freshness window (announce, chat, identity, ack) | ±15 min | §3.1, §5.3, §6, §7 |
| Announcement broadcast interval (LAN) | 5 s | §3.1 |
| Announcement stale expiry | 30 s | §3 |
| Announcement max size (LAN UDP) | 64 KiB | §3.1 |
| Public key max PEM length | 4096 bytes | §3.1 |
| Seen message-ID set size | 512 | §7 |
| Trust record cap | 256 | §4 |
| Identity throttle, per peer, inbound | 2 s | §6.1 |
| Identity reply throttle, per peer | 10 s | §6.1 |
| Identity peer map size (throttles, replied set) | 256 | §6.1 |
| LAN UDP port | 45678 | §3.1 |
| LAN TCP port | 45679 | §8.1 |
| LAN max payload | 16 MiB | §8.1 |
| LAN messages per TCP connection | 8 | §8.1 |
| LAN max concurrent inbound connections | 32 | §8.1 |
| LAN messages per remote address per window | 20 per 10 s | §8.1 |
| LAN TCP idle timeout | 10 s | §8.1 |
| LAN absolute TCP connection lifetime | 60 s | §8.1 |
| LAN aggregate inbound buffer budget | 64 MiB | §8.1 |
| LAN route entries per transport | 512 | §3.1, §8 |
| Known announcement keys per transport | 512 | §3.1, §8 |
| LAN announcements per address per window | 20 per 10 s | §3.1 |
| BLE scanned-device cache | 256 | §8.3 |
| LAN outbound connect timeout | 5 s | §8.1 |
| WiFi Direct TCP port | 8765 | §8.2 |
| WiFi Direct max payload | 10 MiB | §8.2 |
| WiFi Direct socket read timeout | 10 s | §8.2 |
| WiFi Direct connect attempt TTL | 30 s | §8.2 |
| WiFi Direct auto-connect strikes before giving up on a device | 2 | §8.2 |
| BLE chunk size | 180 bytes | §8.3 |
| BLE max payload | 256 KiB | §8.3 |
| BLE max concurrent reassembly buffers | 16 | §8.3 |
| BLE reassembly eviction | 60 s | §8.3 |
| BLE idle GATT disconnect | 5 min | §8.3 |
| Routing table entries (verified UUIDs) | 512 | §8 |
| Routing table entries (temporary ids) | 128 | §8 |
| Identity processing budget (global) | 20 per 10 s | §6.1 |
| Message ID max length | 64 | §5.3 |
| Preview length (reply) | 80 characters | §5.3 |
| Media file max | 5 MiB | §5.3 |
| Media storage quota | 200 MiB | §10 |
| Send retries before `failed` is final | 3 | §5.3 |
| Outbox entries per peer | 50 | §6.3 |
| Max status message length | 80 characters | §2 |
| Max bio length | 200 characters | §2 |
| Password minimum length | 8 characters | §10 |
| PBKDF2 iterations (current) | 310,000 | §10 |

**Note on retries:** the code retries failed text messages when the peer returns. The retry count above limits attempts. A message that exhausts its retries stays `failed` and is not retried again automatically.

---

## Appendix B. Golden vectors

Each signed material and each safety-number function must have a fixed input and an expected output, checked by a test in the suite. A second implementation or a refactor is correct only if it reproduces these exactly.

**Procedure.** Use the fixed inputs below. Generate the expected output with the reference implementation, record it here, and add a test that asserts equality. Signatures are RSA PKCS#1 v1.5, which is deterministic for a given key and message, so the vectors are reproducible once a fixed test key is chosen.

**Status: GENERATED** from the reference implementation on 2026-11-12 with the fixed fixture key stored at `test/fixtures/ahoy_test_key.pem` (private) `ahoy_test_key_pub.pem` (public, A) and `ahoy_test_key_b_pub.pem` (public, B). The full material and signature vectors (which embed the 1.7 KB fixture PEM) live in `test/fixtures/golden_vectors.json` and are asserted by `protocol_golden_vectors_test.dart`. Inputs: uuid A `11111111-1111-4111-8111-111111111111`, uuid B `22222222-2222-4222-8222-222222222222`, timestamp `2026-01-01T00:00:00.000Z`, display name `Peer`, msgId `aaaaaaaa-1111-2222-3333-444444444444`.

| Vector | Input | Expected output |
|---|---|---|
| shortId (A) | uuid A | `21UB4E` |
| shortId (B) | uuid B | `1YA77M` |
| conversationId | uuid A, uuid B | `90b3f6e0fe9888c051f30305c43f6b8a` |
| fingerprint | fixture public PEM | `01872 14387 02303 53318 24168 06683 13314 11704 13391 30096 93208 88467` |
| safety number (A, B) | fixture PEMs A and B | `24079 69395 30751 35902 30767 71844 93019 76170 17801 72928 93986 82379` |
| announce material | fixed field set, timestamp above | `ahoy-announce-v1:{...}` — see `golden_vectors.json` |
| announce signature | fixture key over the material above | see `golden_vectors.json` |
| chat v3 material | fixed inner payload | `ahoy-chat-v3:{...}` — see `golden_vectors.json` |
| chat v3 signature | fixture key over the material above | see `golden_vectors.json` |
| ack material | fixed ack payload | `ahoy-ack-v1:{...}` — see `golden_vectors.json` |
| ack signature | fixture key over the material above | see `golden_vectors.json` |
| identity material | fixed identity payload | `ahoy-identity-v1:{...}` — see `golden_vectors.json` |
| identity signature | fixture key over the material above | see `golden_vectors.json` |

**Fixed test key.** Use one 2048-bit RSA key pair generated once and stored under `test/fixtures/`. Never use a production key.

---

## Appendix C. Glossary

- **Routing UUID**: the `from` field outside the sealed envelope.
- **Pinned key**: the sender key recorded for a conversation at its first accepted message.
- **Pending key**: a conflicting key observed later for a UUID, held for user review and never applied.
- **Drop**: see §6.5.
- **Sealed**: encrypted to a recipient key and signed inside the blob.

---

## Appendix D. Recommended resolutions for open decisions (§12)

These are recommendations, not decisions. Accept or override each one, record the outcome in §13, then delete the item from §12.

| # | Item | Recommendation | Reason |
|---|---|---|---|
| 1 | Signature padding | Switch to RSA-PSS (SHA-256) before first release. | No released users yet, so the breaking change is free now and expensive later. If pointycastle PSS interop is a blocker, keep v1.5 and record it as an accepted risk. |
| 2 | AAD | Bind `v` and routing `from` as GCM AAD. | Cheap, closes the `from`-swap class of issues without relying on the inner check alone. |
| 3 | Replay set | Key by `(convId, msgId)`, raise the cap, and persist it per conversation for the freshness window. | The in-memory set is lost on restart, so a captured message can be replayed after a relaunch. |
| 4 | Forward secrecy | Out of scope for v1. State this in §1 as a non-goal. | A ratchet is a separate protocol. Declaring it out of scope stops it from reappearing as a finding. |
| 5 | Discovery privacy | Keep display name public, keep the status message public, and document it in the app's privacy text. Offer Off the Grid as the mitigation. | Discovery must work before keys are exchanged. The toggle already exists. |
| 6 | Key-binding persistence | Persist the first-seen key per UUID (the trust store) across restarts. | Today a restart resets first-key-wins for LAN and WiFi Direct, which reopens the first-announcement race. |
| 7 | Clock dependence | Keep ±15 min for v1. Show a clear UI message when messages are rejected for skew. | A challenge-response is a larger change. A visible error removes the silent-failure usability problem. |

---

## Appendix E. Release gate

The protocol is releasable when every line below is true.

1. Every **OPEN** item in §12 is resolved and recorded in §13.
2. Every **CODE MISMATCH** is either fixed in code or accepted in §13 with a reason.
3. Appendix B has no `TBD` values and each vector is asserted by a test.
4. Every rule in §3 to §8 has at least one test, and the gaps listed in §14 are closed.
5. Appendix A matches `constants.dart` and the transport code, checked by one test that reads both.
6. Parsers for untrusted input (JSON envelopes, PEM, base64, BLE chunks, UDP announcements, length-prefixed frames) have fuzz or property tests.
7. One consolidated review is run against this document. The review passes when it returns no finding above low severity.
8. Android release signing is configured and R8 is either enabled with verified keep rules or recorded as a deliberate omission.

After the gate passes, the wire format is frozen. Later changes require a new envelope version.

---

## Appendix F. Document precedence

This specification overrides `README.md` wherever they differ. The README is descriptive and has drifted: it still lists media read permissions the manifest no longer requests, and describes a legacy flat payload fallback that the code now rejects. Update or trim the README to link here instead of restating protocol details.
