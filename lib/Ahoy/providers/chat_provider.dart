import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../core/enums.dart';
import '../core/logging.dart';
import '../services/chat/chat_service.dart';
import '../services/chat/conversation_store.dart';
import '../services/chat/message_store.dart';
import '../services/crypto/peer_trust_store.dart';
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

  int get totalUnreadCount =>
      _conversations.fold(0, (sum, conv) => sum + conv.unreadCount);

  ChatProvider(
    this._chatService,
    this._convStore,
    this._msgStore,
    this._transport,
  );

  void init({
    required String myUuid,
    String? myShortId,
    String? myDisplayName,
    String? myPublicKeyPEM,
    required bool Function() receiveOff,
    required Set<String> blockedUuids,
  }) {
    _inboundSub?.cancel();
    _chatService.attachBlockedPeers(blockedUuids);
    _conversations = _convStore.loadAll();
    notifyListeners();

    _inboundSub = _transport.packetStream.listen((packet) async {
      try {
        final msg = await _chatService.onInboundPacket(
          rawPayload: packet.payload,
          peerUuid: packet.peerUuid,
          peerShortId: packet.peerShortId,
          peerDisplayName: packet.peerDisplayName,
          myUuid: myUuid,
          myShortId: myShortId,
          myDisplayName: myDisplayName,
          myPublicKeyPEM: myPublicKeyPEM,
          transport: packet.transport,
          receiveOff: receiveOff(),
          blockedUuids: blockedUuids,
        );
        if (msg != null) {
          // Invalidate cache so messagesFor() reloads from store (which has full
          // history + this new message). Without this, the cache would hold only
          // new messages received this session, losing all prior history.
          _messages.remove(msg.conversationId);
          _conversations = _convStore.loadAll();
          notifyListeners();
        }
      } catch (e) {
        ahoyLog('[ChatProvider] inbound packet error', e);
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
    required String peerDisplayName,
    required String peerShortId,
    required MessageType type,
    required String content,
    String? myPublicKeyPEM,
    String? peerPublicKeyPEM,
    String? replyToId,
    String? replyToPreview,
  }) async {
    _error = null;
    try {
      final sentMsg = await _chatService.sendMessage(
        myUuid: myUuid,
        myShortId: myShortId,
        myDisplayName: myDisplayName,
        peerUuid: peerUuid,
        peerDisplayName: peerDisplayName,
        peerShortId: peerShortId,
        type: type,
        content: content,
        myPublicKeyPEM: myPublicKeyPEM,
        peerPublicKeyPEM: peerPublicKeyPEM,
        replyToId: replyToId,
        replyToPreview: replyToPreview,
      );
      _messages.remove(sentMsg.conversationId);
      _conversations = _convStore.loadAll();
      notifyListeners();
      return sentMsg;
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

  /// Records a discovery-verified key for first-contact pinning (audit #7).
  /// Returns false when a different key was already known for the peer: the
  /// first key wins and the conflict is surfaced instead of applied
  /// (audit H-2).
  bool registerVerifiedPeerKey(String uuid, String pem) =>
      _chatService.registerVerifiedPeerKey(uuid, pem);

  /// Trust record for [uuid], or null when the peer is unknown this session.
  PeerTrust? peerTrust(String uuid) => _chatService.peerTrust(uuid);

  /// The user compared safety numbers out of band (audit H-2). Notifies so
  /// open profile screens drop the key-change banner immediately.
  void promotePeerBySafetyNumber(String uuid) {
    _chatService.promotePeerBySafetyNumber(uuid);
    notifyListeners();
  }

  /// Clears all per-session chat state (called on sign-out, audit #3).
  void reset() {
    _inboundSub?.cancel();
    _inboundSub = null;
    _messages.clear();
    _conversations = [];
    _chatService.reset();
    _error = null;
    notifyListeners();
  }

  void maybeRetryFor(String peerUuid) {
    if (!_chatService.hasPendingFor(peerUuid)) return;
    unawaited(_retryPending(peerUuid));
  }

  Future<void> _retryPending(String peerUuid) async {
    final touched = await _chatService.retryPendingFor(peerUuid);
    if (touched.isEmpty) return;
    for (final convId in touched) {
      _messages.remove(convId);
    }
    _conversations = _convStore.loadAll();
    notifyListeners();
  }

  @override
  void dispose() {
    _inboundSub?.cancel();
    super.dispose();
  }
}
