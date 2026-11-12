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
  final LocalDataCrypto? _localDataCrypto;

  MessageStore(this._prefs, [this._localDataCrypto]);

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
    final crypto = _localDataCrypto;
    return raw != null && crypto != null && !crypto.isEncryptedValue(raw);
  }

  List<Message> loadMessages(String conversationId) {
    return _loadJsonList(conversationId).map(Message.fromJson).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<void> addMessage(Message message) async {
    await _withLock(message.conversationId, () async {
      final all = loadMessages(message.conversationId);
      if (all.any((m) => m.id == message.id)) return;
      all.add(message);
      await _saveMessages(message.conversationId, all);
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

  static String conversationId(String myUuid, String peerUuid) {
    return CryptoService.conversationId(myUuid, peerUuid);
  }

  List<Map<String, dynamic>> _loadJsonList(String conversationId) {
    final key = _key(conversationId);
    final raw = _prefs.getString(key);
    if (raw == null) return [];

    final crypto = _localDataCrypto;
    if (crypto != null && crypto.isEncryptedValue(raw)) {
      final decoded = jsonDecode(crypto.decryptString(raw)) as List;
      return decoded.cast<Map<String, dynamic>>();
    }

    return _prefs.getJsonList(key);
  }

  Future<void> _saveMessages(
    String conversationId,
    List<Message> messages,
  ) async {
    final jsonList = messages.map((m) => m.toJson()).toList();
    final crypto = _localDataCrypto;
    if (crypto == null) {
      await _prefs.setJsonList(_key(conversationId), jsonList);
      return;
    }

    await _prefs.setString(
      _key(conversationId),
      crypto.encryptString(jsonEncode(jsonList)),
    );
  }
}
