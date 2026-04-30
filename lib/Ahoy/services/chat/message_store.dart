import 'dart:async';
import '../../models/message.dart';
import '../../core/enums.dart';
import '../storage/prefs_store.dart';
import '../crypto/crypto_service.dart';

class MessageStore {
  final PrefsStore _prefs;

  MessageStore(this._prefs);

  // Per-conversation async mutex — mirrors ConversationStore._withLock.
  // Prevents concurrent send+receive from overwriting each other via read→dedup→write.
  final _locks = <String, bool>{};
  final _queues = <String, List<Completer<void>>>{};

  Future<T> _withLock<T>(String convId, Future<T> Function() fn) async {
    if (_locks[convId] == true) {
      final gate = Completer<void>();
      (_queues[convId] ??= []).add(gate);
      await gate.future;
    }
    _locks[convId] = true;
    try {
      return await fn();
    } finally {
      _locks[convId] = false;
      final q = _queues[convId];
      if (q != null && q.isNotEmpty) {
        q.removeAt(0).complete();
      }
    }
  }

  String _key(String conversationId) => 'ahoy_msgs_$conversationId';

  List<Message> loadMessages(String conversationId) {
    return _prefs
        .getJsonList(_key(conversationId))
        .map(Message.fromJson)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<void> addMessage(Message message) async {
    await _withLock(message.conversationId, () async {
      final all = loadMessages(message.conversationId);
      if (all.any((m) => m.id == message.id)) return;
      all.add(message);
      await _prefs.setJsonList(_key(message.conversationId), all.map((m) => m.toJson()).toList());
    });
  }

  Future<void> updateMessageStatus(String conversationId, String messageId, MessageStatus status) async {
    await _withLock(conversationId, () async {
      final all = loadMessages(conversationId);
      final idx = all.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        all[idx] = all[idx].copyWith(status: status);
        await _prefs.setJsonList(_key(conversationId), all.map((m) => m.toJson()).toList());
      }
    });
  }

  Future<void> deleteConversationMessages(String conversationId) async {
    await _prefs.remove(_key(conversationId));
  }

  static String conversationId(String myUuid, String peerUuid) {
    return CryptoService.conversationId(myUuid, peerUuid);
  }
}
