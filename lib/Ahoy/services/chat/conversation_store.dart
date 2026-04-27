import '../../core/constants.dart';
import '../../models/conversation.dart';
import '../storage/prefs_store.dart';

class ConversationStore {
  final PrefsStore _prefs;

  ConversationStore(this._prefs);

  List<Conversation> loadAll() {
    return _prefs
        .getJsonList(AhoyConstants.prefConversations)
        .map(Conversation.fromJson)
        .where((c) => !c.isDeleted)
        .toList()
      ..sort((a, b) => (b.lastMessageAt ?? b.createdAt).compareTo(a.lastMessageAt ?? a.createdAt));
  }

  Future<void> saveAll(List<Conversation> conversations) async {
    await _prefs.setJsonList(
      AhoyConstants.prefConversations,
      conversations.map((c) => c.toJson()).toList(),
    );
  }

  Future<Conversation> upsert(Conversation conversation) async {
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
    await saveAll(all);
    return conversation;
  }

  Future<void> setBlocked(String conversationId, bool blocked) async {
    final all = _prefs
        .getJsonList(AhoyConstants.prefConversations)
        .map(Conversation.fromJson)
        .toList();
    final idx = all.indexWhere((c) => c.id == conversationId);
    if (idx >= 0) {
      all[idx] = all[idx].copyWith(isBlocked: blocked);
      await saveAll(all);
    }
  }

  Future<void> softDelete(String conversationId) async {
    final all = _prefs
        .getJsonList(AhoyConstants.prefConversations)
        .map(Conversation.fromJson)
        .toList();
    final idx = all.indexWhere((c) => c.id == conversationId);
    if (idx >= 0) {
      all[idx] = all[idx].copyWith(isDeleted: true);
      await saveAll(all);
    }
  }

  Future<void> markRead(String conversationId) async {
    final all = _prefs
        .getJsonList(AhoyConstants.prefConversations)
        .map(Conversation.fromJson)
        .toList();
    final idx = all.indexWhere((c) => c.id == conversationId);
    if (idx >= 0) {
      all[idx] = all[idx].copyWith(unreadCount: 0);
      await saveAll(all);
    }
  }
}
