import 'dart:async';
import '../../core/constants.dart';
import '../../models/conversation.dart';
import '../storage/prefs_store.dart';

class ConversationStore {
  final PrefsStore _prefs;

  ConversationStore(this._prefs);

  // Simple async mutex: serialises all read-modify-write operations so
  // concurrent send + receive can't lose each other's updates.
  bool _locked = false;
  final _queue = <Completer<void>>[];

  Future<T> _withLock<T>(Future<T> Function() fn) async {
    if (_locked) {
      final gate = Completer<void>();
      _queue.add(gate);
      await gate.future;
    }
    _locked = true;
    try {
      return await fn();
    } finally {
      _locked = false;
      if (_queue.isNotEmpty) {
        _queue.removeAt(0).complete();
      }
    }
  }

  List<Conversation> loadAll() {
    return _prefs
        .getJsonList(AhoyConstants.prefConversations)
        .map(Conversation.fromJson)
        .where((c) => !c.isDeleted)
        .toList()
      ..sort((a, b) =>
          (b.lastMessageAt ?? b.createdAt).compareTo(a.lastMessageAt ?? a.createdAt));
  }

  Future<void> _saveAll(List<Conversation> conversations) async {
    await _prefs.setJsonList(
      AhoyConstants.prefConversations,
      conversations.map((c) => c.toJson()).toList(),
    );
  }

  Future<Conversation> upsert(Conversation conversation) {
    return _withLock(() async {
      final all = _prefs
          .getJsonList(AhoyConstants.prefConversations)
          .map(Conversation.fromJson)
          .toList();
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

  Future<void> setBlocked(String conversationId, bool blocked) {
    return _withLock(() async {
      final all = _prefs
          .getJsonList(AhoyConstants.prefConversations)
          .map(Conversation.fromJson)
          .toList();
      final idx = all.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(isBlocked: blocked);
        await _saveAll(all);
      }
    });
  }

  Future<void> softDelete(String conversationId) {
    return _withLock(() async {
      final all = _prefs
          .getJsonList(AhoyConstants.prefConversations)
          .map(Conversation.fromJson)
          .toList();
      final idx = all.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(isDeleted: true);
        await _saveAll(all);
      }
    });
  }

  Future<void> markRead(String conversationId) {
    return _withLock(() async {
      final all = _prefs
          .getJsonList(AhoyConstants.prefConversations)
          .map(Conversation.fromJson)
          .toList();
      final idx = all.indexWhere((c) => c.id == conversationId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(unreadCount: 0);
        await _saveAll(all);
      }
    });
  }
}
