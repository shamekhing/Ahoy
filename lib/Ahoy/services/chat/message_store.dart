import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../models/message.dart';
import '../../core/enums.dart';
import '../crypto/local_data_crypto.dart';
import '../storage/prefs_store.dart';
import '../crypto/crypto_service.dart';

class MessageStore {
  final PrefsStore _prefs;

  /// Required since the ninth review: a plaintext write path for message
  /// rows must not exist, even latently (spec §10, matching the round-8
  /// ProfileService decision). Legacy plaintext rows are still readable so
  /// the migrator can rewrite them encrypted.
  final LocalDataCrypto _localDataCrypto;

  MessageStore(this._prefs, this._localDataCrypto);

  // Per-conversation async mutex mirrors ConversationStore._withLock.
  // Prevents concurrent send+receive from overwriting each other via read→dedup→write.
  // Lock ownership is handed to the next queued waiter while the flag stays
  // true, so a caller arriving between release and wake-up queues behind it
  // instead of racing it (audit M-3).
  final _locks = <String, bool>{};
  final _queues = <String, List<Completer<void>>>{};

  // Test instrumentation: proves at most one critical section runs at a time
  // across all conversations.
  int _activeEntries = 0;
  int _maxConcurrentEntries = 0;

  @visibleForTesting
  int get debugMaxConcurrentEntries => _maxConcurrentEntries;

  Future<T> _withLock<T>(String convId, Future<T> Function() fn) async {
    if (_locks[convId] == true) {
      final gate = Completer<void>();
      (_queues[convId] ??= []).add(gate);
      await gate.future; // the previous owner handed the lock over
    } else {
      _locks[convId] = true;
    }
    _activeEntries++;
    if (_activeEntries > _maxConcurrentEntries) {
      _maxConcurrentEntries = _activeEntries;
    }
    try {
      return await fn();
    } finally {
      _activeEntries--;
      final q = _queues[convId];
      if (q == null || q.isEmpty) {
        _locks[convId] = false;
      } else {
        // Hand the lock to the next waiter: the flag stays true so a fresh
        // caller queues instead of entering concurrently (audit M-3).
        q.removeAt(0).complete();
      }
    }
  }

  static const String messageKeyPrefix = 'ahoy_msgs_';

  String _key(String conversationId) => '$messageKeyPrefix$conversationId';

  Set<String> get conversationIds => _prefs
      .keys()
      .where((key) => key.startsWith(messageKeyPrefix))
      .map((key) => key.substring(messageKeyPrefix.length))
      .toSet();

  bool needsLegacyPlaintextMigration(String conversationId) {
    final raw = _prefs.getString(_key(conversationId));
    return raw != null && !_localDataCrypto.isEncryptedValue(raw);
  }

  List<Message> loadMessages(String conversationId) {
    // Order by the receiver clock when present (round 7): the sender
    // controls `timestamp` and may skew it within the freshness window.
    return _loadJsonList(conversationId).map(Message.fromJson).toList()
      ..sort(
        (a, b) => (a.receivedAt ?? a.timestamp).compareTo(
          b.receivedAt ?? b.timestamp,
        ),
      );
  }

  /// Adds [message] unless a row with the same id already exists. Returns
  /// whether the row was newly added: callers gate state changes (unread
  /// counters, last-message fields) on this so a replay that survived the
  /// in-memory seen-set is state-neutral (round 8, spec §7).
  Future<bool> addMessage(Message message) async {
    return _withLock(message.conversationId, () async {
      final all = loadMessages(message.conversationId);
      if (all.any((m) => m.id == message.id)) return false;
      all.add(message);
      await _saveMessages(message.conversationId, all);
      return true;
    });
  }

  Future<void> updateMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) async {
    await _withLock(conversationId, () async {
      final all = loadMessages(conversationId);
      final idx = all.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(status: status);
        await _saveMessages(conversationId, all);
      }
    });
  }

  Future<void> replaceMessages(
    String conversationId,
    List<Message> messages,
  ) async {
    await _withLock(conversationId, () async {
      await _saveMessages(conversationId, messages);
    });
  }

  Future<void> deleteConversationMessages(String conversationId) async {
    await _prefs.remove(_key(conversationId));
  }

  /// Moves every message stored under [fromId] to [toId], deduplicating by
  /// message id, then removes the old key. Used when a peer first known under
  /// a temporary transport id (a BLE MAC) proves its canonical UUID and the
  /// conversation must follow (ninth review N-1). Both locks are taken in a
  /// fixed sorted order so concurrent migrations cannot deadlock.
  Future<void> migrateConversation(String fromId, String toId) async {
    if (fromId == toId) return;
    final first = fromId.compareTo(toId) <= 0 ? fromId : toId;
    final second = first == fromId ? toId : fromId;
    await _withLock(first, () {
      return _withLock(second, () async {
        final incoming =
            _loadJsonList(fromId).map(Message.fromJson).toList();
        if (incoming.isEmpty) {
          await _prefs.remove(_key(fromId));
          return;
        }
        final kept = <Message>[];
        final seen = <String>{};
        for (final message in incoming) {
          if (seen.add(message.id)) kept.add(message);
        }
        final existing =
            _loadJsonList(toId).map(Message.fromJson).toList();
        final merged = [...existing];
        final existingIds = {for (final message in merged) message.id};
        for (final message in kept) {
          if (!existingIds.contains(message.id)) merged.add(message);
        }
        await _saveMessages(toId, merged);
        await _prefs.remove(_key(fromId));
      });
    });
  }

  static String conversationId(String myUuid, String peerUuid) {
    return CryptoService.conversationId(myUuid, peerUuid);
  }

  List<Map<String, dynamic>> _loadJsonList(String conversationId) {
    final key = _key(conversationId);
    final raw = _prefs.getString(key);
    if (raw == null) return [];

    if (_localDataCrypto.isEncryptedValue(raw)) {
      try {
        final decoded =
            jsonDecode(_localDataCrypto.decryptString(raw)) as List;
        return decoded.cast<Map<String, dynamic>>();
      } catch (_) {
        // Lost or rotated at-rest key: quarantine and start empty instead of
        // throwing on every read (audit M-1).
        unawaited(_prefs.quarantineValue(key));
        return [];
      }
    }

    return _prefs.getJsonList(key);
  }

  Future<void> _saveMessages(
    String conversationId,
    List<Message> messages,
  ) async {
    final jsonList = messages.map((m) => m.toJson()).toList();
    await _prefs.setString(
      _key(conversationId),
      _localDataCrypto.encryptString(jsonEncode(jsonList)),
    );
  }
}
