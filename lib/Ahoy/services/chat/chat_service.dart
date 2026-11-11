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

  /// msgId ends up in media file paths — keep it a bounded UUID-like token.
  static final RegExp _msgIdPattern = RegExp(r'^[0-9a-fA-F-]{1,64}$');

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
      myUuid,
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
    // v3 messages are sealed end-to-end: the whole payload is encrypted.
    final actuallyEncrypted = payload['v'] == 3;
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
    String myUuid,
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
    final wireContent = type == MessageType.text
        ? content
        : _encodeMediaContent(content);

    final canSeal = peerPublicKeyPEM != null && _crypto.isReady;
    final canSign = myPublicKeyPEM != null && _crypto.isReady;

    // v3: the whole message — identity, metadata and content — is encrypted
    // as one blob; only the routing UUID rides outside (audit M-1). The
    // signature over the plaintext inner material travels inside the blob.
    if (canSeal) {
      final inner = <String, dynamic>{
        'msgType': 'chat',
        'msgId': msgId,
        'convId': convId,
        'senderUuid': myUuid,
        'senderShortId': myShortId,
        'senderName': myDisplayName,
        'type': type.name,
        'content': wireContent,
        'replyToId': replyToId,
        'replyToPreview': replyToPreview,
        'timestamp': timestamp.toIso8601String(),
        'senderPublicKeyPEM': myPublicKeyPEM,
      };
      if (canSign) {
        inner['signature'] = _crypto.signPayload(_signatureMaterialV3(inner));
      }
      return {
        'v': 3,
        'ct': _crypto.encryptForPeer(jsonEncode(inner), peerPublicKeyPEM),
      };
    }

    // Legacy flat fallback (no peer key available — e.g. a BLE-only first
    // contact): plaintext metadata, but identity-bound and signed.
    final payload = <String, dynamic>{
      'msgType': 'chat',
      'msgId': msgId,
      'convId': convId,
      'senderUuid': myUuid,
      'senderShortId': myShortId,
      'senderName': myDisplayName,
      'type': type.name,
      'content': wireContent,
      'isEncrypted': false,
      'senderPublicKeyPEM': myPublicKeyPEM,
      'replyToId': replyToId,
      'replyToPreview': replyToPreview,
      'timestamp': timestamp.toIso8601String(),
    };

    if (canSign) {
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
      final outer = jsonDecode(rawPayload) as Map<String, dynamic>;
      final isV3 = outer['v'] == 3;

      if (blockedUuids.contains(peerUuid)) return null;

      // v3: everything except the routing UUID lives inside the encrypted
      // blob — decrypt first, then validate (audit M-1).
      Map<String, dynamic> json;
      if (isV3) {
        if (!_crypto.isReady) {
          ahoyLog('[ChatService] dropping sealed message; crypto not ready');
          return null;
        }
        final ct = outer['ct'] as String?;
        if (ct == null || ct.isEmpty) return null;
        try {
          final plain = _crypto.decryptFromPeer(ct);
          json = jsonDecode(plain) as Map<String, dynamic>;
        } catch (e) {
          ahoyLog('[ChatService] dropping undecryptable sealed message', e);
          return null;
        }
      } else {
        json = outer;
      }

      if (json['msgType'] != 'chat') return null;

      final convId = MessageStore.conversationId(myUuid, peerUuid);
      final isNewConversation = !_convStore.loadAll().any(
        (c) => c.id == convId,
      );
      if (isNewConversation && receiveOff) return null;

      // The claimed sender must match the transport-level identity — for v3
      // the claim is inside the signature, so a spoofed `from` cannot pass.
      final senderUuid = json['senderUuid'] as String? ?? peerUuid;
      if (senderUuid != peerUuid) {
        ahoyLog('[ChatService] dropping message with spoofed sender identity');
        return null;
      }

      // Bind the message to this conversation — captured payloads replayed
      // into another conversation fail here (audit M-2).
      final innerConvId = json['convId'] as String? ?? '';
      if (innerConvId != convId) {
        ahoyLog('[ChatService] dropping message for a different conversation');
        return null;
      }

      // Freshness window — the timestamp is covered by the signature, so
      // captured payloads older than the skew bound cannot be replayed.
      final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
      if (timestamp == null) return null;
      final age = DateTime.now().difference(timestamp);
      if (age.abs() >
          const Duration(seconds: AhoyConstants.inboundMaxClockSkewSeconds)) {
        ahoyLog('[ChatService] dropping message outside freshness window');
        return null;
      }

      // msgId ends up in media file names — bound length and charset.
      final msgId = json['msgId'] as String? ?? '';
      if (msgId.isEmpty ||
          msgId.length > AhoyConstants.maxMsgIdLength ||
          !_msgIdPattern.hasMatch(msgId)) {
        ahoyLog('[ChatService] dropping message with invalid msgId');
        return null;
      }

      final senderPublicKeyPEM = json['senderPublicKeyPEM'] as String?;
      final existingConversation = _findConversation(convId);
      final trustedPeerPublicKeyPEM = _resolvePeerPublicKey(
        pinnedKey: existingConversation?.peerPublicKeyPEM,
        candidateKey: senderPublicKeyPEM,
      );
      if (!_verifyInboundSignature(
        json,
        trustedPeerPublicKeyPEM,
        v3: isV3,
      )) {
        return null;
      }

      final type = MessageType.values.byName(json['type'] as String? ?? 'text');
      final isEncrypted = isV3 || (json['isEncrypted'] as bool? ?? false);
      String content = json['content'] as String? ?? '';

      if (!isV3 && isEncrypted && _crypto.isReady) {
        try {
          content = _crypto.decryptFromPeer(content);
        } catch (e) {
          ahoyLog('[ChatService] decryption failed', e);
          content = '[Message could not be decrypted]';
        }
      }

      // Signed identity fields win over transport-level hints (which are
      // empty for sealed messages).
      final senderShortId =
          _nonEmpty(json['senderShortId'] as String?) ?? peerShortId;
      final senderName =
          _nonEmpty(json['senderName'] as String?) ?? peerDisplayName;

      if (type == MessageType.image || type == MessageType.voice) {
        content = await _saveMediaToFile(content, msgId, type);
      }

      final message = Message(
        id: msgId,
        conversationId: convId,
        senderId: peerUuid,
        type: type,
        content: content,
        replyToId: json['replyToId'] as String?,
        replyToPreview: json['replyToPreview'] as String?,
        status: MessageStatus.sent,
        transport: transport,
        timestamp: timestamp,
        isEncrypted: isEncrypted,
      );

      await _msgStore.addMessage(message);
      await _updateConversationOnReceive(
        convId,
        peerUuid,
        senderShortId,
        senderName,
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
    String? trustedPeerPublicKeyPEM, {
    bool v3 = false,
  }) {
    if (trustedPeerPublicKeyPEM == null || trustedPeerPublicKeyPEM.isEmpty) {
      // No pinned key and none presented — there is nothing to verify against.
      // Unauthenticated messages must never be displayed or stored (audit H-1).
      ahoyLog('[ChatService] dropping unkeyed inbound message');
      return false;
    }

    final signature = payload['signature'] as String?;
    if (signature == null || signature.isEmpty) {
      ahoyLog('[ChatService] dropping unsigned message');
      return false;
    }

    final ok = _crypto.verifyPayloadSignature(
      v3 ? _signatureMaterialV3(payload) : _signatureMaterial(payload),
      signature,
      trustedPeerPublicKeyPEM,
    );
    if (!ok) {
      ahoyLog('[ChatService] dropping message with invalid signature');
    }
    return ok;
  }

  /// Signature material for legacy flat (pre-v3) payloads.
  String _signatureMaterial(Map<String, dynamic> payload) {
    return jsonEncode({
      'msgType': payload['msgType'],
      'msgId': payload['msgId'],
      'convId': payload['convId'],
      'senderUuid': payload['senderUuid'],
      'senderShortId': payload['senderShortId'],
      'senderName': payload['senderName'],
      'type': payload['type'],
      'content': payload['content'],
      'isEncrypted': payload['isEncrypted'],
      'senderPublicKeyPEM': payload['senderPublicKeyPEM'],
      'replyToId': payload['replyToId'],
      'replyToPreview': payload['replyToPreview'],
      'timestamp': payload['timestamp'],
    });
  }

  /// Signature material for sealed (v3) inner payloads. Frozen field set —
  /// changing it breaks verification of previously sent messages.
  String _signatureMaterialV3(Map<String, dynamic> payload) {
    return jsonEncode({
      'msgType': payload['msgType'],
      'msgId': payload['msgId'],
      'convId': payload['convId'],
      'senderUuid': payload['senderUuid'],
      'senderShortId': payload['senderShortId'],
      'senderName': payload['senderName'],
      'type': payload['type'],
      'content': payload['content'],
      'replyToId': payload['replyToId'],
      'replyToPreview': payload['replyToPreview'],
      'timestamp': payload['timestamp'],
      'senderPublicKeyPEM': payload['senderPublicKeyPEM'],
    });
  }

  bool _samePublicKey(String a, String b) {
    return _canonicalPublicKey(a) == _canonicalPublicKey(b);
  }

  String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  String _canonicalPublicKey(String key) {
    return key.replaceAll(_pemWhitespace, '');
  }
}
