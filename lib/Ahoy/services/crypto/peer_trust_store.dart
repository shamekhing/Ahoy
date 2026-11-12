import 'package:flutter/foundation.dart';

import '../../core/logging.dart';

/// How strongly a peer's key is trusted for first-contact decisions.
enum PeerTrustState {
  /// Key seen only in a self-signed announcement or identity exchange. Good
  /// enough to seal messages to and to reject conflicting first contacts,
  /// not enough to claim the peer is who they say they are.
  unverified,

  /// The peer proved ownership of this key by signing a chat message we
  /// accepted for a pinned conversation.
  pinned,

  /// The user compared safety numbers out of band.
  verifiedBySafetyNumber,
}

/// Immutable snapshot of one peer's key trust.
class PeerTrust {
  final String uuid;
  final String key;
  final PeerTrustState state;

  /// A different key observed later for this UUID. Never used for sealing or
  /// verification; it exists so the UI can warn that the peer's announced
  /// identity changed (audit H-2).
  final String? pendingKey;

  const PeerTrust({
    required this.uuid,
    required this.key,
    required this.state,
    this.pendingKey,
  });

  PeerTrust copyWith({String? pendingKey, PeerTrustState? state}) {
    return PeerTrust(
      uuid: uuid,
      key: key,
      state: state ?? this.state,
      pendingKey: pendingKey ?? this.pendingKey,
    );
  }
}

/// Single authority for "which public key belongs to this peer UUID".
///
/// Key learning is monotonic: the first key observed for a UUID wins, and a
/// conflicting key is recorded as [PeerTrust.pendingKey] but never applied.
/// Before this store existed, `ChatService` overwrote verified keys
/// unconditionally while `DiscoveryService` refused to, so a forged
/// self-signed identity could poison first contact, silently lock out the
/// real peer, or redirect queued first messages into an attacker's key
/// (audit H-2).
class PeerTrustStore {
  /// Bound on attacker-chosen UUID entries; eviction prefers unverified
  /// records (audit M-8).
  static const int maxEntries = 256;

  final _peers = <String, PeerTrust>{};

  PeerTrust? get(String uuid) => _peers[uuid];

  /// Records a key observed for [uuid]. Returns the resulting record.
  PeerTrust observe(String uuid, String key) {
    if (uuid.isEmpty || key.isEmpty) {
      throw ArgumentError('uuid and key must not be empty');
    }
    final existing = _peers[uuid];
    if (existing == null) {
      final record = PeerTrust(
        uuid: uuid,
        key: key,
        state: PeerTrustState.unverified,
      );
      _peers[uuid] = record;
      _evictIfOverCap();
      return record;
    }
    if (_sameKey(existing.key, key)) return existing;
    if (existing.pendingKey != null && _sameKey(existing.pendingKey!, key)) {
      return existing;
    }
    ahoyLog('[Trust] conflicting key observed for $uuid; keeping known key');
    final updated = existing.copyWith(pendingKey: key);
    _peers[uuid] = updated;
    return updated;
  }

  /// True when [key] is the known key for [uuid]. Unknown UUIDs return false.
  bool keyMatches(String uuid, String key) {
    final record = _peers[uuid];
    return record != null && _sameKey(record.key, key);
  }

  /// The peer proved ownership of the observed key (first accepted signed
  /// chat message or a conversation pin).
  void markPinned(String uuid) {
    final record = _peers[uuid];
    if (record == null || record.state != PeerTrustState.unverified) return;
    _peers[uuid] = record.copyWith(state: PeerTrustState.pinned);
  }

  /// The user compared safety numbers out of band.
  void markSafetyNumberVerified(String uuid) {
    final record = _peers[uuid];
    if (record == null) return;
    if (record.state == PeerTrustState.verifiedBySafetyNumber) return;
    _peers[uuid] = record.copyWith(state: PeerTrustState.verifiedBySafetyNumber);
  }

  void clear() => _peers.clear();

  int get length => _peers.length;

  @visibleForTesting
  Map<String, PeerTrust> get debugSnapshot => Map.unmodifiable(_peers);

  void _evictIfOverCap() {
    while (_peers.length > maxEntries) {
      String? unverifiedKey;
      for (final entry in _peers.entries) {
        if (entry.value.state == PeerTrustState.unverified) {
          unverifiedKey = entry.key;
          break;
        }
      }
      final victim = unverifiedKey ?? _peers.keys.first;
      _peers.remove(victim);
    }
  }

  static bool _sameKey(String a, String b) {
    final ws = RegExp(r'\s+');
    return a.replaceAll(ws, '') == b.replaceAll(ws, '');
  }
}
