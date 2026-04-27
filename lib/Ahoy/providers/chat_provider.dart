import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../core/enums.dart';
import '../services/chat/chat_service.dart';
import '../services/chat/conversation_store.dart';
import '../services/chat/message_store.dart';
import '../services/transport_manager.dart';

class ChatProvider extends ChangeNotifier {
  final ChatService _chatService;
  final ConversationStore _convStore;
  final MessageStore _msgStore;
  final TransportManager _transport;

  List<Conversation> _conversations = [];
  final Map<String, List<Message>> _messages = {};
  String? _error;

  StreamSubscription? _inboundSub;

  List<Conversation> get conversations => _conversations;
  String? get error => _error;

  ChatProvider(this._chatService, this._convStore, this._msgStore, this._transport);

  void init({
    required String myUuid,
    required bool Function() receiveOff,
    required Set<String> blockedUuids,
  }) {
    _conversations = _convStore.loadAll();
    notifyListeners();

    _inboundSub = _transport.packetStream.listen((packet) async {
      final msg = await _chatService.onInboundPacket(
        rawPayload: packet.payload,
        peerUuid: packet.peerUuid,
        peerShortId: packet.peerShortId,
        peerDisplayName: packet.peerDisplayName,
        myUuid: myUuid,
        transport: packet.transport,
        receiveOff: receiveOff(),
        blockedUuids: blockedUuids,
      );
      if (msg != null) {
        _messages.putIfAbsent(msg.conversationId, () => []).add(msg);
        _conversations = _convStore.loadAll();
        notifyListeners();
      }
    });
  }

  List<Message> messagesFor(String conversationId) {
    if (!_messages.containsKey(conversationId)) {
      _messages[conversationId] = _msgStore.loadMessages(conversationId);
    }
    return _messages[conversationId]!;
  }

  Future<Message?> sendMessage({
    required String myUuid,
    required String myShortId,
    required String myDisplayName,
    required String peerUuid,
    required MessageType type,
    required String content,
    String? replyToId,
    String? replyToPreview,
  }) async {
    _error = null;
    try {
      final msg = await _chatService.sendMessage(
        myUuid: myUuid,
        myShortId: myShortId,
        myDisplayName: myDisplayName,
        peerUuid: peerUuid,
        type: type,
        content: content,
        replyToId: replyToId,
        replyToPreview: replyToPreview,
      );
      _messages.putIfAbsent(msg.conversationId, () => []).add(msg);
      _conversations = _convStore.loadAll();
      notifyListeners();
      return msg;
    } catch (e) {
      _error = e.toString().replaceFirst('TransportError: ', '');
      notifyListeners();
      return null;
    }
  }

  Future<void> markRead(String conversationId) async {
    await _convStore.markRead(conversationId);
    _conversations = _convStore.loadAll();
    notifyListeners();
  }

  Future<void> blockConversation(String conversationId) async {
    await _convStore.setBlocked(conversationId, true);
    _conversations = _convStore.loadAll();
    notifyListeners();
  }

  Future<void> unblockConversation(String conversationId) async {
    await _convStore.setBlocked(conversationId, false);
    _conversations = _convStore.loadAll();
    notifyListeners();
  }

  Future<void> deleteConversation(String conversationId) async {
    await _convStore.softDelete(conversationId);
    await _msgStore.deleteConversationMessages(conversationId);
    _messages.remove(conversationId);
    _conversations = _convStore.loadAll();
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _inboundSub?.cancel();
    super.dispose();
  }
}
