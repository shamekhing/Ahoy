import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/enums.dart';
import '../../core/errors.dart';
import '../../core/logging.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../crypto/crypto_service.dart';
import '../crypto/local_data_crypto.dart';
import '../transport_manager.dart';
import 'conversation_store.dart';
import 'message_store.dart';

class ChatService {
  static final RegExp _pemWhitespace = RegExp(r'\s+');

  final TransportManager _transport;
  final ConversationStore _convStore;
  final MessageStore _msgStore;
  final CryptoService _crypto;
  final LocalDataCrypto? _localDataCrypto;

  ChatService(
    this._transport,
    this._convStore,
    this._msgStore,
    this._crypto, [
    this._localDataCrypto,
  ]);

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
        throw TransportError(
          'Media messages require LAN or WiFi Direct connection',
        );
      }
    }

    if (mode == TransportMode.none) {
      throw TransportError('Peer is not reachable on any transport');
    }

    final convId = MessageStore.conversationId(myUuid, peerUuid);
    final existingConversation = _findConversation(convId);
    final trustedPeerPublicKeyPEM = _resolvePeerPublicKey(
      pinnedKey: existingConversation?.peerPublicKeyPEM,
      candidateKey: peerPublicKeyPEM,
    );
    final msgId = const Uuid().v4();
    final timestamp = DateTime.now();

    // Build payload first so we know whether encryption actually succeeded.
    final payload = _buildPayload(
      msgId,
      convId,
      myShortId,
      myDisplayName,
      type,
      content,
      replyToId,
      replyToPreview,
      timestamp,
      myPublicKeyPEM,
      trustedPeerPublicKeyPEM,
    );
    final actuallyEncrypted = payload['isEncrypted'] as bool? ?? false;
    final storedContent = await _storedContentForLocalMessage(
      type: type,
      content: content,
      msgId: msgId,
    );

    final message = Message(
      id: msgId,
      conversationId: convId,
      senderId: myUuid,
      type: type,
      content: storedContent,
      replyToId: replyToId,
      replyToPreview: replyToPreview,
      status: MessageStatus.sending,
      transport: mode,
      timestamp: timestamp,
      isEncrypted: actuallyEncrypted,
    );

    await _msgStore.addMessage(message);
    await _updateConversationOnSend(
      convId,
      peerUuid,
      peerDisplayName,
      peerShortId,
      trustedPeerPublicKeyPEM,
      message,
    );

    final sent = await _transport.send(
      peerUuid,
      myUuid,
      myShortId,
      myDisplayName,
      payload,
    );

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
      wireContent = _crypto.encryptForPeer(wireContent, peerPublicKeyPEM);
      encrypted = true;
    }

    final payload = {
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

    if (myPublicKeyPEM != null && _crypto.isReady) {
      payload['signatureVersion'] = 1;
      payload['signature'] = _crypto.signPayload(_signatureMaterial(payload));
    }

    return payload;
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

  Future<String> _storedContentForLocalMessage({
    required MessageType type,
    required String content,
    required String msgId,
  }) async {
    if (type == MessageType.text ||
        content.isEmpty ||
        _localDataCrypto == null) {
      return content;
    }

    try {
      final source = File(content);
      if (!await source.exists()) return content;
      final bytes = await source.readAsBytes();
      final storedPath = await _writeEncryptedMedia(bytes, msgId, type);

      final fileName = source.uri.pathSegments.isEmpty
          ? ''
          : source.uri.pathSegments.last;
      if (fileName.startsWith('ahoy_voice_')) {
        try {
          await source.delete();
        } catch (_) {}
      }

      return storedPath;
    } catch (_) {
      return content;
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
      final isNewConversation = !_convStore.loadAll().any(
        (c) => c.id == convId,
      );
      if (isNewConversation && receiveOff) return null;

      final senderPublicKeyPEM = json['senderPublicKeyPEM'] as String?;
      final existingConversation = _findConversation(convId);
      final trustedPeerPublicKeyPEM = _resolvePeerPublicKey(
        pinnedKey: existingConversation?.peerPublicKeyPEM,
        candidateKey: senderPublicKeyPEM,
      );
      if (!_verifyInboundSignature(json, trustedPeerPublicKeyPEM)) {
        return null;
      }

      final type = MessageType.values.byName(json['type'] as String? ?? 'text');
      final isEncrypted = json['isEncrypted'] as bool? ?? false;
      String content = json['content'] as String? ?? '';

      if (isEncrypted && _crypto.isReady) {
        try {
          content = _crypto.decryptFromPeer(content);
        } catch (e) {
          ahoyLog('[ChatService] decryption failed', e);
          content = '[Message could not be decrypted]';
        }
      }

      if (type == MessageType.image || type == MessageType.voice) {
        content = await _saveMediaToFile(
          content,
          json['msgId'] as String,
          type,
        );
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

      await _msgStore.addMessage(message);
      await _updateConversationOnReceive(
        convId,
        peerUuid,
        peerShortId,
        peerDisplayName,
        trustedPeerPublicKeyPEM,
        message,
        transport,
      );
      return message;
    } catch (e) {
      ahoyLog('[ChatService] inbound packet failed', e);
      return null;
    }
  }

  Future<String> _saveMediaToFile(
    String base64Content,
    String msgId,
    MessageType type,
  ) async {
    try {
      final bytes = base64.decode(base64Content);
      return await _writeEncryptedMedia(bytes, msgId, type);
    } catch (_) {
      return '';
    }
  }

  Future<String> _writeEncryptedMedia(
    List<int> bytes,
    String msgId,
    MessageType type,
  ) async {
    // Use app-private documents directory so the OS doesn't evict the files
    // and other apps cannot read them without permission.
    final dir = await getApplicationDocumentsDirectory();
    final ext = type == MessageType.image ? 'jpg' : 'aac';
    final crypto = _localDataCrypto;
    if (crypto == null) {
      final file = File('${dir.path}/ahoy_media_$msgId.$ext');
      await file.writeAsBytes(bytes);
      return file.path;
    }

    final file = File(
      '${dir.path}/ahoy_media_$msgId.$ext${LocalDataCrypto.encryptedFileExtension}',
    );
    await crypto.writeEncryptedFile(file, Uint8List.fromList(bytes));
    return file.path;
  }

  Future<void> _updateConversationOnSend(
    String convId,
    String peerUuid,
    String peerDisplayName,
    String peerShortId,
    String? peerPublicKeyPEM,
    Message msg,
  ) async {
    final existing = _findConversation(convId);
    final trustedPeerPublicKeyPEM = _resolvePeerPublicKey(
      pinnedKey: existing?.peerPublicKeyPEM,
      candidateKey: peerPublicKeyPEM,
    );
    final conversation =
        existing ??
        Conversation(
          id: convId,
          peerUuid: peerUuid,
          peerDisplayName: peerDisplayName,
          peerShortId: peerShortId,
          peerPublicKeyPEM: trustedPeerPublicKeyPEM,
          lastTransport: msg.transport,
          createdAt: DateTime.now(),
        );
    await _convStore.upsert(
      conversation.copyWith(
        lastTransport: msg.transport,
        lastMessageAt: msg.timestamp,
        lastMessagePreview: msg.type == MessageType.text
            ? msg.content
            : '[${msg.type.name}]',
        peerPublicKeyPEM: trustedPeerPublicKeyPEM,
      ),
    );
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
    final existing = _findConversation(convId);
    final trustedPeerPublicKeyPEM = _resolvePeerPublicKey(
      pinnedKey: existing?.peerPublicKeyPEM,
      candidateKey: peerPublicKeyPEM,
    );
    final conversation =
        existing ??
        Conversation(
          id: convId,
          peerUuid: peerUuid,
          peerShortId: peerShortId,
          peerPublicKeyPEM: trustedPeerPublicKeyPEM,
          peerDisplayName: peerDisplayName,
          lastTransport: transport,
          createdAt: DateTime.now(),
        );
    await _convStore.upsert(
      conversation.copyWith(
        lastTransport: transport,
        lastMessageAt: msg.timestamp,
        lastMessagePreview: msg.type == MessageType.text
            ? msg.content
            : '[${msg.type.name}]',
        unreadCount: conversation.unreadCount + 1,
        // Update peer identity fields if we now have better data.
        peerShortId: peerShortId.isNotEmpty ? peerShortId : null,
        peerPublicKeyPEM: trustedPeerPublicKeyPEM,
      ),
    );
  }

  Conversation? _findConversation(String convId) {
    for (final conversation in _convStore.loadAll()) {
      if (conversation.id == convId) return conversation;
    }
    return null;
  }

  String? _resolvePeerPublicKey({
    required String? pinnedKey,
    required String? candidateKey,
  }) {
    if (pinnedKey == null || pinnedKey.isEmpty) return candidateKey;
    if (candidateKey == null || candidateKey.isEmpty) return pinnedKey;
    if (_samePublicKey(pinnedKey, candidateKey)) return pinnedKey;

    ahoyLog('[ChatService] ignoring changed peer public key');
    return pinnedKey;
  }

  bool _verifyInboundSignature(
    Map<String, dynamic> payload,
    String? trustedPeerPublicKeyPEM,
  ) {
    if (trustedPeerPublicKeyPEM == null || trustedPeerPublicKeyPEM.isEmpty) {
      return true;
    }

    final signature = payload['signature'] as String?;
    if (signature == null || signature.isEmpty) {
      ahoyLog('[ChatService] dropping unsigned message');
      return false;
    }

    final ok = _crypto.verifyPayloadSignature(
      _signatureMaterial(payload),
      signature,
      trustedPeerPublicKeyPEM,
    );
    if (!ok) {
      ahoyLog('[ChatService] dropping message with invalid signature');
    }
    return ok;
  }

  String _signatureMaterial(Map<String, dynamic> payload) {
    return jsonEncode({
      'msgType': payload['msgType'],
      'msgId': payload['msgId'],
      'convId': payload['convId'],
      'type': payload['type'],
      'content': payload['content'],
      'isEncrypted': payload['isEncrypted'],
      'senderPublicKeyPEM': payload['senderPublicKeyPEM'],
      'replyToId': payload['replyToId'],
      'replyToPreview': payload['replyToPreview'],
      'timestamp': payload['timestamp'],
    });
  }

  bool _samePublicKey(String a, String b) {
    return _canonicalPublicKey(a) == _canonicalPublicKey(b);
  }

  String _canonicalPublicKey(String key) {
    return key.replaceAll(_pemWhitespace, '');
  }
}
