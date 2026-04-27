import '../../models/message.dart';
import '../../core/enums.dart';
import '../storage/prefs_store.dart';
import '../crypto/crypto_service.dart';

class MessageStore {
  final PrefsStore _prefs;

  MessageStore(this._prefs);

  String _key(String conversationId) => 'ahoy_msgs_$conversationId';

  List<Message> loadMessages(String conversationId) {
    return _prefs
        .getJsonList(_key(conversationId))
        .map(Message.fromJson)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<void> addMessage(Message message) async {
    final all = loadMessages(message.conversationId);
    // Deduplicate by id
    if (all.any((m) => m.id == message.id)) return;
    all.add(message);
    await _prefs.setJsonList(_key(message.conversationId), all.map((m) => m.toJson()).toList());
  }

  Future<void> updateMessageStatus(String conversationId, String messageId, MessageStatus status) async {
    final all = loadMessages(conversationId);
    final idx = all.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      all[idx] = all[idx].copyWith(status: status);
      await _prefs.setJsonList(_key(conversationId), all.map((m) => m.toJson()).toList());
    }
  }

  Future<void> deleteConversationMessages(String conversationId) async {
    await _prefs.remove(_key(conversationId));
  }

  static String conversationId(String myUuid, String peerUuid) {
    return CryptoService.conversationId(myUuid, peerUuid);
  }
}
