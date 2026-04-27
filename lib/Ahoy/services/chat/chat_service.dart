import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../../core/enums.dart';
import '../../core/errors.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../transport_manager.dart';
import 'conversation_store.dart';
import 'message_store.dart';

class ChatService {
  final TransportManager _transport;
  final ConversationStore _convStore;
  final MessageStore _msgStore;

  ChatService(this._transport, this._convStore, this._msgStore);

  /// Send a message to a peer. Throws [TransportError] for media over BLE.
  Future<Message> sendMessage({
    required String myUuid,
    required String myShortId,
    required String myDisplayName,
    required String peerUuid,
    required MessageType type,
    required String content,
    String? replyToId,
    String? replyToPreview,
  }) async {
    final mode = _transport.currentModeFor(peerUuid);

    // Media guard: images and voice only over LAN or WiFi Direct
    if (type == MessageType.image || type == MessageType.voice) {
      if (mode == TransportMode.ble || mode == TransportMode.none) {
        throw TransportError('Media messages require LAN or WiFi Direct connection');
      }
    }

    if (mode == TransportMode.none) {
      throw TransportError('Peer is not reachable on any transport');
    }

    final convId = MessageStore.conversationId(myUuid, peerUuid);
    final msgId = const Uuid().v4();

    final message = Message(
      id: msgId,
      conversationId: convId,
      senderId: myUuid,
      type: type,
      content: content,
      replyToId: replyToId,
      replyToPreview: replyToPreview,
      status: MessageStatus.sending,
      transport: mode,
      timestamp: DateTime.now(),
    );

    await _msgStore.addMessage(message);

    // Update conversation preview
    await _updateConversationOnSend(convId, peerUuid, message);

    // Send over transport
    final payload = _buildPayload(message, myShortId, myDisplayName, type, content);
    final sent = await _transport.send(peerUuid, myUuid, myShortId, myDisplayName, payload);

    final finalStatus = sent ? MessageStatus.sent : MessageStatus.failed;
    await _msgStore.updateMessageStatus(convId, msgId, finalStatus);

    return message.copyWith(status: finalStatus);
  }

  Map<String, dynamic> _buildPayload(
    Message msg,
    String myShortId,
    String myDisplayName,
    MessageType type,
    String content,
  ) {
    return {
      'msgType': 'chat',
      'msgId': msg.id,
      'convId': msg.conversationId,
      'type': type.name,
      'content': type == MessageType.text ? content : _encodeMediaContent(content),
      'replyToId': msg.replyToId,
      'replyToPreview': msg.replyToPreview,
      'timestamp': msg.timestamp.toIso8601String(),
    };
  }

  String _encodeMediaContent(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return '';
      final bytes = file.readAsBytesSync();
      return base64.encode(bytes);
    } catch (_) {
      return '';
    }
  }

  /// Called when an inbound packet arrives. Returns null if the message should be dropped.
  Future<Message?> onInboundPacket({
    required String rawPayload,
    required String peerUuid,
    required String peerShortId,
    required String peerDisplayName,
    required String myUuid,
    required TransportMode transport,
    required bool receiveOff,
    required Set<String> blockedUuids,
  }) async {
    try {
      final json = jsonDecode(rawPayload) as Map<String, dynamic>;
      if (json['msgType'] != 'chat') return null;
      if (blockedUuids.contains(peerUuid)) return null;

      final convId = MessageStore.conversationId(myUuid, peerUuid);
      final isNewConversation = !_convStore.loadAll().any((c) => c.id == convId);
      if (isNewConversation && receiveOff) return null;

      final type = MessageType.values.byName(json['type'] as String? ?? 'text');
      String content = json['content'] as String? ?? '';

      // Decode media content to local file if needed
      if (type == MessageType.image || type == MessageType.voice) {
        content = await _saveMediaToFile(content, json['msgId'] as String, type);
      }

      final message = Message(
        id: json['msgId'] as String,
        conversationId: convId,
        senderId: peerUuid,
        type: type,
        content: content,
        replyToId: json['replyToId'] as String?,
        replyToPreview: json['replyToPreview'] as String?,
        status: MessageStatus.sent,
        transport: transport,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );

      await _msgStore.addMessage(message);
      await _updateConversationOnReceive(convId, peerUuid, peerDisplayName, message, transport);
      return message;
    } catch (_) {
      return null;
    }
  }

  Future<String> _saveMediaToFile(String base64Content, String msgId, MessageType type) async {
    try {
      final bytes = base64.decode(base64Content);
      final dir = Directory.systemTemp;
      final ext = type == MessageType.image ? 'jpg' : 'aac';
      final file = File('${dir.path}/ahoy_media_$msgId.$ext');
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (_) {
      return '';
    }
  }

  Future<void> _updateConversationOnSend(String convId, String peerUuid, Message msg) async {
    final existing = _convStore.loadAll().firstWhere(
      (c) => c.id == convId,
      orElse: () => Conversation(
        id: convId,
        peerUuid: peerUuid,
        peerDisplayName: 'Unknown',
        lastTransport: msg.transport,
        createdAt: DateTime.now(),
      ),
    );
    await _convStore.upsert(existing.copyWith(
      lastTransport: msg.transport,
      lastMessageAt: msg.timestamp,
      lastMessagePreview: msg.type == MessageType.text ? msg.content : '[${msg.type.name}]',
    ));
  }

  Future<void> _updateConversationOnReceive(
    String convId,
    String peerUuid,
    String peerDisplayName,
    Message msg,
    TransportMode transport,
  ) async {
    final all = _convStore.loadAll();
    final existing = all.firstWhere(
      (c) => c.id == convId,
      orElse: () => Conversation(
        id: convId,
        peerUuid: peerUuid,
        peerDisplayName: peerDisplayName,
        lastTransport: transport,
        createdAt: DateTime.now(),
      ),
    );
    await _convStore.upsert(existing.copyWith(
      lastTransport: transport,
      lastMessageAt: msg.timestamp,
      lastMessagePreview: msg.type == MessageType.text ? msg.content : '[${msg.type.name}]',
      unreadCount: existing.unreadCount + 1,
    ));
  }
}
