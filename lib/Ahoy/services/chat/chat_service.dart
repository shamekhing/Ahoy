import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/enums.dart';
import '../../core/errors.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../crypto/crypto_service.dart';
import '../transport_manager.dart';
import 'conversation_store.dart';
import 'message_store.dart';

class ChatService {
  final TransportManager _transport;
  final ConversationStore _convStore;
  final MessageStore _msgStore;
  final CryptoService _crypto;

  ChatService(this._transport, this._convStore, this._msgStore, this._crypto);

  /// Send a message to a peer. Throws [TransportError] for media over BLE.
  Future<Message> sendMessage({
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
    final mode = _transport.currentModeFor(peerUuid);

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
    final timestamp = DateTime.now();

    // Build payload first so we know whether encryption actually succeeded.
    final payload = _buildPayload(
      msgId, convId, myShortId, myDisplayName, type, content, replyToId, replyToPreview,
      timestamp, myPublicKeyPEM, peerPublicKeyPEM,
    );
    final actuallyEncrypted = payload['isEncrypted'] as bool? ?? false;

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
      timestamp: timestamp,
      isEncrypted: actuallyEncrypted,
    );

    await _msgStore.addMessage(message);
    await _updateConversationOnSend(convId, peerUuid, peerDisplayName, peerShortId, peerPublicKeyPEM, message);

    final sent = await _transport.send(peerUuid, myUuid, myShortId, myDisplayName, payload);

    final finalStatus = sent ? MessageStatus.sent : MessageStatus.failed;
    await _msgStore.updateMessageStatus(convId, msgId, finalStatus);

    return message.copyWith(status: finalStatus);
  }

  Map<String, dynamic> _buildPayload(
    String msgId,
    String convId,
    String myShortId,
    String myDisplayName,
    MessageType type,
    String content,
    String? replyToId,
    String? replyToPreview,
    DateTime timestamp,
    String? myPublicKeyPEM,
    String? peerPublicKeyPEM,
  ) {
    String wireContent;
    bool encrypted = false;

    if (type == MessageType.text) {
      wireContent = content;
    } else {
      wireContent = _encodeMediaContent(content);
    }

    if (peerPublicKeyPEM != null && _crypto.isReady) {
      try {
        wireContent = _crypto.encryptForPeer(wireContent, peerPublicKeyPEM);
        encrypted = true;
      } catch (e) {
        debugPrint('[ChatService] Encryption failed, sending plaintext: $e');
      }
    }

    return {
      'msgType': 'chat',
      'msgId': msgId,
      'convId': convId,
      'type': type.name,
      'content': wireContent,
      'isEncrypted': encrypted,
      'senderPublicKeyPEM': myPublicKeyPEM,
      'replyToId': replyToId,
      'replyToPreview': replyToPreview,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  String _encodeMediaContent(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return '';
      return base64.encode(file.readAsBytesSync());
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
      final isEncrypted = json['isEncrypted'] as bool? ?? false;
      String content = json['content'] as String? ?? '';

      if (isEncrypted && _crypto.isReady) {
        try {
          content = _crypto.decryptFromPeer(content);
        } catch (e) {
          debugPrint('[ChatService] Decryption failed, dropping message: $e');
          return null;
        }
      }

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
        isEncrypted: isEncrypted,
      );

      final senderPublicKeyPEM = json['senderPublicKeyPEM'] as String?;

      await _msgStore.addMessage(message);
      await _updateConversationOnReceive(
          convId, peerUuid, peerShortId, peerDisplayName, senderPublicKeyPEM, message, transport);
      return message;
    } catch (e, st) {
      debugPrint('[ChatService] onInboundPacket failed: $e\n$st');
      return null;
    }
  }

  Future<String> _saveMediaToFile(String base64Content, String msgId, MessageType type) async {
    try {
      final bytes = base64.decode(base64Content);
      // Use app-private documents directory so the OS doesn't evict the files
      // and other apps cannot read them without permission.
      final dir = await getApplicationDocumentsDirectory();
      final ext = type == MessageType.image ? 'jpg' : 'aac';
      final file = File('${dir.path}/ahoy_media_$msgId.$ext');
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (_) {
      return '';
    }
  }

  Future<void> _updateConversationOnSend(
    String convId,
    String peerUuid,
    String peerDisplayName,
    String peerShortId,
    String? peerPublicKeyPEM,
    Message msg,
  ) async {
    final existing = _convStore.loadAll().firstWhere(
      (c) => c.id == convId,
      orElse: () => Conversation(
        id: convId,
        peerUuid: peerUuid,
        peerDisplayName: peerDisplayName,
        peerShortId: peerShortId,
        peerPublicKeyPEM: peerPublicKeyPEM,
        lastTransport: msg.transport,
        createdAt: DateTime.now(),
      ),
    );
    await _convStore.upsert(existing.copyWith(
      lastTransport: msg.transport,
      lastMessageAt: msg.timestamp,
      lastMessagePreview: msg.type == MessageType.text ? msg.content : '[${msg.type.name}]',
      peerPublicKeyPEM: peerPublicKeyPEM ?? existing.peerPublicKeyPEM,
    ));
  }

  Future<void> _updateConversationOnReceive(
    String convId,
    String peerUuid,
    String peerShortId,
    String peerDisplayName,
    String? peerPublicKeyPEM,
    Message msg,
    TransportMode transport,
  ) async {
    final all = _convStore.loadAll();
    final existing = all.firstWhere(
      (c) => c.id == convId,
      orElse: () => Conversation(
        id: convId,
        peerUuid: peerUuid,
        peerShortId: peerShortId,
        peerPublicKeyPEM: peerPublicKeyPEM,
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
      // Update peer identity fields if we now have better data.
      peerShortId: peerShortId.isNotEmpty ? peerShortId : null,
      peerPublicKeyPEM: peerPublicKeyPEM ?? existing.peerPublicKeyPEM,
    ));
  }
}
