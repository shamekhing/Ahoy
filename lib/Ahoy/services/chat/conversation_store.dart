import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../models/conversation.dart';
import '../crypto/local_data_crypto.dart';
import '../storage/prefs_store.dart';

class ConversationStore {
  final PrefsStore _prefs;
  final LocalDataCrypto? _localDataCrypto;

  ConversationStore(this._prefs, [this._localDataCrypto]);

  // Simple async mutex: serialises all read-modify-write operations so
  // concurrent send + receive can't lose each other's updates. Lock ownership
  // is handed to the next queued waiter while _locked stays true, so a caller
  // that arrives between one release and the waiter's wake-up queues behind
  // it instead of racing it (audit M-3).
  bool _locked = false;
  final _queue = <Completer<void>>[];

  // Test instrumentation: proves at most one critical section runs at a time.
  int _activeEntries = 0;
  int _maxConcurrentEntries = 0;

  @visibleForTesting
  int get debugMaxConcurrentEntries => _maxConcurrentEntries;

  Future<T> _withLock<T>(Future<T> Function() fn) async {
    if (_locked) {
      final gate = Completer<void>();
      _queue.add(gate);
      await gate.future; // the previous owner handed the lock over
    } else {
      _locked = true;
    }
    _activeEntries++;
    if (_activeEntries > _maxConcurrentEntries) {
      _maxConcurrentEntries = _activeEntries;
    }
    try {
      return await fn();
    } finally {
      _activeEntries--;
      if (_queue.isEmpty) {
        _locked = false;
      } else {
        // Hand the lock to the next waiter: _locked stays true so a fresh
        // caller queues instead of entering concurrently (audit M-3).
        _queue.removeAt(0).complete();
      }
    }
  }

  List<Conversation> loadAll() {
    return _loadAllJson()
        .map(Conversation.fromJson)
        .where((c) => !c.isDeleted)
        .toList()
      ..sort(
        (a, b) => (b.lastMessageAt ?? b.createdAt).compareTo(
          a.lastMessageAt ?? a.createdAt,
        ),
      );
  }

  bool get hasStoredData =>
      _prefs.getString(AhoyConstants.prefConversations) != null;

  /// True when [conversationId] exists as a soft-deleted tombstone. Inbound
  /// messages for deleted threads are dropped instead of silently
  /// accumulating behind the tombstone (round 7, external review A#3).
  bool isSoftDeleted(String conversationId) {
    for (final json in _loadAllJson()) {
      final conversation = Conversation.fromJson(json);
      if (conversation.id == conversationId) return conversation.isDeleted;
    }
    return false;
  }

  bool get needsLegacyPlaintextMigration {
    final raw = _prefs.getString(AhoyConstants.prefConversations);
    final crypto = _localDataCrypto;
    return raw != null && crypto != null && !crypto.isEncryptedValue(raw);
  }

  Future<void> rewriteAll() {
    return _withLock(() async {
      await _saveAll(_loadAllJson().map(Conversation.fromJson).toList());
    });
  }

  Future<void> _saveAll(List<Conversation> conversations) async {
    final jsonList = conversations.map((c) => c.toJson()).toList();
    final crypto = _localDataCrypto;
    if (crypto == null) {
      await _prefs.setJsonList(AhoyConstants.prefConversations, jsonList);
      return;
    }

    await _prefs.setString(
      AhoyConstants.prefConversations,
      crypto.encryptString(jsonEncode(jsonList)),
    );
  }

  Future<Conversation> upsert(Conversation conversation) {
    return _withLock(() async {
      final all = _loadAllJson().map(Conversation.fromJson).toList();
      final idx = all.indexWhere((c) => c.id == conversation.id);
      if (idx >= 0) {
        all[idx] = conversation;
      } else {
        all.add(conversation);
      }
      await _saveAll(all);
      return conversation;
    });
  }

  /// Atomic read-modify-write under the store lock: [mutate] sees the
  /// freshest record and its result is written back inside the same locked
  /// section, so concurrent updates (e.g. a Block tap racing an inbound
  /// message) cannot be clobbered (third review #3). Creates the
  /// conversation when [mutate] returns one for a missing record.
  Future<Conversation> mutateOrCreate(
    String conversationId,
    Conversation Function(Conversation? existing) mutate,
  ) {
    return _withLock(() async {
      final all = _loadAllJson().map(Conversation.fromJson).toList();
      final idx = all.indexWhere((c) => c.id == conversationId);
      final existing = idx >= 0 ? all[idx] : null;
      final updated = mutate(existing);
      if (idx >= 0) {
        all[idx] = updated;
      } else {
        all.add(updated);
      }
      await _saveAll(all);
      return updated;
    });
  }

  Future<void> setBlocked(String conversationId, bool blocked) {
    return _withLock(() async {
      final all = _loadAllJson().map(Conversation.fromJson).toList();
      final idx = all.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(isBlocked: blocked);
        await _saveAll(all);
      }
    });
  }

  Future<void> softDelete(String conversationId) {
    return _withLock(() async {
      final all = _loadAllJson().map(Conversation.fromJson).toList();
      final idx = all.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(isDeleted: true);
        await _saveAll(all);
      }
    });
  }

  Future<void> markRead(String conversationId) {
    return _withLock(() async {
      final all = _loadAllJson().map(Conversation.fromJson).toList();
      final idx = all.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(unreadCount: 0);
        await _saveAll(all);
      }
    });
  }

  List<Map<String, dynamic>> _loadAllJson() {
    final raw = _prefs.getString(AhoyConstants.prefConversations);
    if (raw == null) return [];

    final crypto = _localDataCrypto;
    if (crypto != null && crypto.isEncryptedValue(raw)) {
      try {
        final decoded = jsonDecode(crypto.decryptString(raw)) as List;
        return decoded.cast<Map<String, dynamic>>();
      } catch (_) {
        // Lost or rotated at-rest key: quarantine and start empty instead of
        // throwing from every caller, including app startup (audit M-1).
        unawaited(_prefs.quarantineValue(AhoyConstants.prefConversations));
        return [];
      }
    }

    return _prefs.getJsonList(AhoyConstants.prefConversations);
  }
}
