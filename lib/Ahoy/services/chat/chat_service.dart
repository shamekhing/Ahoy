import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/enums.dart';
import '../../core/errors.dart';
import '../../core/logging.dart';
import '../../core/constants.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../crypto/crypto_service.dart';
import '../crypto/local_data_crypto.dart';
import '../transport_manager.dart';
import 'conversation_store.dart';
import 'message_store.dart';

class ChatService {
  static final RegExp _pemWhitespace = RegExp(r'\s+');

  /// msgId ends up in media file paths keep it a bounded UUID-like token.
  static final RegExp _msgIdPattern = RegExp(r'^[0-9a-fA-F-]{1,64}$');

  final TransportManager _transport;
  final ConversationStore _convStore;
  final MessageStore _msgStore;
  final CryptoService _crypto;
  final LocalDataCrypto? _localDataCrypto;

  /// Text messages that failed to send, queued per peer for automatic retry
  /// when the peer is next seen in discovery (audit M-3).
  final _outbox = <String, List<_PendingSend>>{};

  /// Public keys verified via signed announcements or identity exchanges,
  /// per peer uuid first contacts must pin to these when available
  /// (audit #7).
  final _verifiedKeys = <String, String>{};

  /// Live reference to the discovery-owned blocked set enforced on the
  /// sending path too (third review #4).
  Set<String> _blockedUuids = const {};

  /// Bounded replay guard: message ids seen this session are dropped on
  /// replay even if the conversation was deleted meanwhile (third review
  /// #2). Only authenticated messages enter the cache, so garbage cannot
  /// flush it.
  final _seenMessageIds = <String>{};
  static const int _maxSeenMessageIds = 512;

  /// Hands the live blocked-peers set to the service (audit #4). The set is
  /// owned by DiscoveryProvider and mutated in place.
  void attachBlockedPeers(Set<String> peers) => _blockedUuids = peers;

  /// Last identity send per peer throttles identity broadcasts (audit #1).
  final _identitySentAt = <String, DateTime>{};

  /// Peers we already answered with our own identity (reply-once guard).
  final _identityRepliedTo = <String>{};

  /// Records a discovery-verified public key for [uuid] (audit #7).
  void registerVerifiedPeerKey(String uuid, String pem) {
    if (uuid.isEmpty || pem.isEmpty) return;
    _verifiedKeys[uuid] = pem;
  }

  /// Clears all per-session state (called on sign-out, audit #3).
  void reset() {
    _outbox.clear();
    _verifiedKeys.clear();
    _identitySentAt.clear();
    _identityRepliedTo.clear();
    _seenMessageIds.clear();
    _blockedUuids = const {};
  }
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

    if (_blockedUuids.contains(peerUuid)) {
      // The UI hides the composer for blocked conversations, but the service
      // is the authority block is enforced on the sending path too
      // (third review #4).
      throw const TransportError('Peer is blocked');
    }

    final convId = MessageStore.conversationId(myUuid, peerUuid);
    final existingConversation = _findConversation(convId);
    // Discovery-verified keys participate in first-contact resolution too
    // (audit #7): a key learned from a signed announcement or identity
    // exchange is as good as one passed in by the UI.
    final candidateKey = peerPublicKeyPEM ?? _verifiedKeys[peerUuid];
    final trustedPeerPublicKeyPEM = _resolvePeerPublicKey(
      pinnedKey: existingConversation?.peerPublicKeyPEM,
      candidateKey: candidateKey,
    );
    final msgId = const Uuid().v4();
    final timestamp = DateTime.now();

    final media = type == MessageType.text
        ? null
        : await _prepareOutgoingMedia(type: type, content: content, msgId: msgId);
    final storedContent = media?.stored ?? content;

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
      isEncrypted: trustedPeerPublicKeyPEM != null,
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

    if (trustedPeerPublicKeyPEM == null) {
      // No verified key yet (e.g. BLE-only first contact scan responses
      // carry no key). Sending plaintext content would contradict the E2EE
      // claim, so announce our signed identity instead, queue the real
      // message, and wait for the peer's signed identity in return
      // (audit #1).
      await _sendIdentity(
        peerUuid: peerUuid,
        myUuid: myUuid,
        myShortId: myShortId,
        myDisplayName: myDisplayName,
        myPublicKeyPEM: myPublicKeyPEM,
      );
      if (!_outboxHas(peerUuid, msgId) &&
          (_outbox[peerUuid]?.length ?? 0) < AhoyConstants.maxOutboxPerPeer) {
        _outbox.putIfAbsent(peerUuid, () => []).add(
          _PendingSend(
            msgId: msgId,
            convId: convId,
            peerUuid: peerUuid,
            peerDisplayName: peerDisplayName,
            peerShortId: peerShortId,
            type: type,
            content: content,
            mediaBase64: media?.wire,
            replyToId: replyToId,
            replyToPreview: replyToPreview,
            myUuid: myUuid,
            myShortId: myShortId,
            myDisplayName: myDisplayName,
            myPublicKeyPEM: myPublicKeyPEM,
            peerPublicKeyPEM: null,
          ),
        );
      }
      ahoyLog('[ChatService] message queued until the peer identity is known');
      return message.copyWith(status: MessageStatus.sending);
    }

    // Build payload now that we know the message will be sealed.
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
      mediaBase64: media?.wire,
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

    if (!sent &&
        type == MessageType.text &&
        (_outbox[peerUuid]?.length ?? 0) < AhoyConstants.maxOutboxPerPeer &&
        !_outboxHas(peerUuid, msgId)) {
      _outbox.putIfAbsent(peerUuid, () => []).add(
        _PendingSend(
          msgId: msgId,
          convId: convId,
          peerUuid: peerUuid,
          peerDisplayName: peerDisplayName,
          peerShortId: peerShortId,
          type: type,
          content: content,
          mediaBase64: media?.wire,
          replyToId: replyToId,
          replyToPreview: replyToPreview,
          myUuid: myUuid,
          myShortId: myShortId,
          myDisplayName: myDisplayName,
          myPublicKeyPEM: myPublicKeyPEM,
          peerPublicKeyPEM: trustedPeerPublicKeyPEM,
        ),
      );
      ahoyLog('[ChatService] queued message for retry when peer returns');
    }

    return message.copyWith(status: finalStatus);
  }

  /// True when [peerUuid] has messages waiting for a send retry.
  bool hasPendingFor(String peerUuid) =>
      _outbox[peerUuid]?.isNotEmpty ?? false;

  bool _outboxHas(String peerUuid, String msgId) =>
      _outbox[peerUuid]?.any((p) => p.msgId == msgId) ?? false;

  /// Re-attempts all pending sends to [peerUuid]. Called when discovery
  /// suggests the peer is reachable again. Returns the conversation ids whose
  /// message statuses changed.
  Future<List<String>> retryPendingFor(String peerUuid) async {
    final queue = _outbox.remove(peerUuid);
    if (queue == null || queue.isEmpty) return const [];

    final touched = <String>{};
    final requeue = <_PendingSend>[];
    for (final item in queue) {
      item.attempts += 1;
      try {
        final peerKey =
            _findConversation(item.convId)?.peerPublicKeyPEM ??
            _verifiedKeys[item.peerUuid] ??
            item.peerPublicKeyPEM;
        final payload = _buildPayload(
          item.myUuid,
          item.msgId,
          item.convId,
          item.myShortId,
          item.myDisplayName,
          item.type,
          item.content,
          item.replyToId,
          item.replyToPreview,
          DateTime.now(), // fresh signature timestamp for the retry
          item.myPublicKeyPEM,
          peerKey,
          mediaBase64: item.mediaBase64,
        );
        final sent = await _transport.send(
          item.peerUuid,
          item.myUuid,
          item.myShortId,
          item.myDisplayName,
          payload,
        );
        if (sent) {
          await _msgStore.updateMessageStatus(
            item.convId,
            item.msgId,
            MessageStatus.sent,
          );
          touched.add(item.convId);
        } else if (item.attempts < AhoyConstants.maxSendRetries) {
          requeue.add(item);
        }
      } catch (e) {
        ahoyLog('[ChatService] retry failed', e);
        if (item.attempts < AhoyConstants.maxSendRetries) requeue.add(item);
      }
    }
    if (requeue.isNotEmpty) _outbox[peerUuid] = requeue;
    return touched.toList();
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
    String? peerPublicKeyPEM, {
    String? mediaBase64,
  }) {
    final wireContent = type == MessageType.text
        ? content
        : (mediaBase64 ?? _encodeMediaContent(content));

    final canSeal = peerPublicKeyPEM != null && _crypto.isReady;
    final canSign = myPublicKeyPEM != null && _crypto.isReady;

    if (!canSeal) {
      // Reaching here means no verified recipient key was available —
      // sending plaintext content would break the E2EE guarantee (audit #1).
      throw const TransportError('No verified recipient key for this peer');
    }

    // v3: the whole message identity, metadata and content is encrypted
    // as one blob; only the routing UUID rides outside (audit M-1). The
    // signature over the plaintext inner material travels inside the blob.
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

  /// Encodes media for the wire. Only a fallback for retries that carry no
  /// prepared bytes: a missing source is a hard failure, never an empty
  /// payload (audit H-1).
  String _encodeMediaContent(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw const TransportError('Media source unavailable');
    }
    return base64.encode(file.readAsBytesSync());
  }

  /// Prepares a media message for sending: reads the source bytes once,
  /// writes the encrypted-at-rest copy, and returns both the stored path and
  /// the base64 wire content. The wire bytes are captured before the source
  /// file is deleted so voice messages never go out empty (audit H-1).
  /// Throws [TransportError] when the source is missing or empty, which
  /// surfaces as a visible send error instead of a silent empty message.
  Future<_PreparedMedia> _prepareOutgoingMedia({
    required MessageType type,
    required String content,
    required String msgId,
  }) async {
    final source = File(content);
    if (content.isEmpty || !await source.exists()) {
      throw const TransportError('Media source unavailable');
    }
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty) {
      throw const TransportError('Media source unavailable');
    }
    final wire = base64.encode(bytes);
    final stored = await _writeEncryptedMedia(bytes, msgId, type);

    // The voice recorder's temp file is owned by us and is dead weight once
    // the encrypted copy exists. Images from the picker are cleaned up by the
    // media lifecycle pass (audit M-5).
    final fileName = source.uri.pathSegments.isEmpty
        ? ''
        : source.uri.pathSegments.last;
    if (fileName.startsWith('ahoy_voice_')) {
      try {
        await source.delete();
      } catch (_) {}
    }

    return (stored: stored, wire: wire);
  }

  /// Called when an inbound packet arrives. Returns null if the message should be dropped.
  Future<Message?> onInboundPacket({
    required String rawPayload,
    required String peerUuid,
    required String peerShortId,
    required String peerDisplayName,
    required String myUuid,
    String? myShortId,
    String? myDisplayName,
    String? myPublicKeyPEM,
    required TransportMode transport,
    required bool receiveOff,
    required Set<String> blockedUuids,
  }) async {
    try {
      final outer = jsonDecode(rawPayload) as Map<String, dynamic>;
      final isV3 = outer['v'] == 3;

      if (blockedUuids.contains(peerUuid)) return null;

      if (outer['msgType'] == 'identity') {
        await _handleInboundIdentity(
          outer,
          peerUuid,
          myUuid,
          myShortId: myShortId,
          myDisplayName: myDisplayName,
          myPublicKeyPEM: myPublicKeyPEM,
        );
        return null;
      }

      // v3: everything except the routing UUID lives inside the encrypted
      // blob decrypt first, then validate (audit M-1).
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

      if (json['msgType'] == 'ack') {
        await _handleInboundAck(json, peerUuid, myUuid);
        return null;
      }
      if (json['msgType'] != 'chat') return null;

      final convId = MessageStore.conversationId(myUuid, peerUuid);
      final isNewConversation = !_convStore.loadAll().any(
        (c) => c.id == convId,
      );
      if (isNewConversation && receiveOff) return null;

      // The claimed sender must match the transport-level identity for v3
      // the claim is inside the signature, so a spoofed `from` cannot pass.
      final senderUuid = json['senderUuid'] as String? ?? peerUuid;
      if (senderUuid != peerUuid) {
        ahoyLog('[ChatService] dropping message with spoofed sender identity');
        return null;
      }

      // Bind the message to this conversation captured payloads replayed
      // into another conversation fail here (audit M-2).
      final innerConvId = json['convId'] as String? ?? '';
      if (innerConvId != convId) {
        ahoyLog('[ChatService] dropping message for a different conversation');
        return null;
      }

      // Freshness window the timestamp is covered by the signature, so
      // captured payloads older than the skew bound cannot be replayed.
      final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
      if (timestamp == null) return null;
      final age = DateTime.now().difference(timestamp);
      if (age.abs() >
          const Duration(seconds: AhoyConstants.inboundMaxClockSkewSeconds)) {
        ahoyLog('[ChatService] dropping message outside freshness window');
        return null;
      }

      // msgId ends up in media file names bound length and charset.
      final msgId = json['msgId'] as String? ?? '';
      if (msgId.isEmpty ||
          msgId.length > AhoyConstants.maxMsgIdLength ||
          !_msgIdPattern.hasMatch(msgId)) {
        ahoyLog('[ChatService] dropping message with invalid msgId');
        return null;
      }

      final senderPublicKeyPEM = json['senderPublicKeyPEM'] as String?;
      final existingConversation = _findConversation(convId);
      // A discovery-verified key must match on first contact otherwise an
      // impersonator messaging first pins their own key and the real peer is
      // silently locked out (audit #7).
      final verifiedKey = _verifiedKeys[peerUuid];
      final pinnedKey = existingConversation?.peerPublicKeyPEM;
      final hasPinnedKey = pinnedKey != null && pinnedKey.isNotEmpty;
      if (!hasPinnedKey &&
          verifiedKey != null &&
          (senderPublicKeyPEM == null ||
              !_samePublicKey(senderPublicKeyPEM, verifiedKey))) {
        ahoyLog('[ChatService] dropping first contact with unverified key');
        return null;
      }
      final trustedPeerPublicKeyPEM = _resolvePeerPublicKey(
        pinnedKey: pinnedKey,
        candidateKey: senderPublicKeyPEM,
      );
      if (!_verifyInboundSignature(
        json,
        trustedPeerPublicKeyPEM,
        v3: isV3,
      )) {
        return null;
      }

      // Bounded replay guard a captured packet replayed after the
      // conversation was deleted must not resurrect messages (third review
      // #2). Only authenticated messages reach this point, so garbage cannot
      // flush the cache.
      if (_seenMessageIds.contains(msgId)) {
        ahoyLog('[ChatService] dropping replayed message');
        return null;
      }
      _seenMessageIds.add(msgId);
      if (_seenMessageIds.length > _maxSeenMessageIds) {
        _seenMessageIds.remove(_seenMessageIds.first);
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
        if (content.isEmpty) {
          ahoyLog('[ChatService] dropping media message with empty content');
          return null;
        }
        final saved = await _saveMediaToFile(content, msgId, type);
        if (saved == null) {
          ahoyLog('[ChatService] dropping undecodable media message');
          return null;
        }
        content = saved;
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
      await _sendAck(
        convId: convId,
        ackFor: msgId,
        senderKey: trustedPeerPublicKeyPEM,
        myUuid: myUuid,
        peerUuid: peerUuid,
      );
      return message;
    } catch (e) {
      ahoyLog('[ChatService] inbound packet failed', e);
      return null;
    }
  }

  /// Decodes and stores inbound media. Returns null when the payload is not
  /// decodable media so the caller drops the message instead of storing a
  /// zero-byte file (audit H-1).
  Future<String?> _saveMediaToFile(
    String base64Content,
    String msgId,
    MessageType type,
  ) async {
    try {
      final bytes = base64.decode(base64Content);
      if (bytes.isEmpty) return null;
      return await _writeEncryptedMedia(bytes, msgId, type);
    } catch (e) {
      ahoyLog('[ChatService] media decode failed', e);
      return null;
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
    // Atomic read-modify-write (third review #3).
    await _convStore.mutateOrCreate(convId, (existing) {
      final conversation =
          existing ??
          Conversation(
            id: convId,
            peerUuid: peerUuid,
            peerDisplayName: peerDisplayName,
            peerShortId: peerShortId,
            peerPublicKeyPEM: peerPublicKeyPEM,
            lastTransport: msg.transport,
            createdAt: DateTime.now(),
          );
      return conversation.copyWith(
        lastTransport: msg.transport,
        lastMessageAt: msg.timestamp,
        lastMessagePreview: msg.type == MessageType.text
            ? msg.content
            : '[${msg.type.name}]',
        peerShortId: peerShortId.isNotEmpty ? peerShortId : null,
        peerPublicKeyPEM: peerPublicKeyPEM,
      );
    });
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
    // Atomic read-modify-write a concurrent Block or markRead can no
    // longer be clobbered by a stale full-record write-back (third
    // review #3).
    await _convStore.mutateOrCreate(convId, (existing) {
      final conversation =
          existing ??
          Conversation(
            id: convId,
            peerUuid: peerUuid,
            peerShortId: peerShortId,
            peerPublicKeyPEM: peerPublicKeyPEM,
            peerDisplayName: peerDisplayName,
            lastTransport: transport,
            createdAt: DateTime.now(),
          );
      return conversation.copyWith(
        lastTransport: transport,
        lastMessageAt: msg.timestamp,
        lastMessagePreview: msg.type == MessageType.text
            ? msg.content
            : '[${msg.type.name}]',
        unreadCount: conversation.unreadCount + 1,
        // Update peer identity fields if we now have better data.
        peerShortId: peerShortId.isNotEmpty ? peerShortId : null,
        peerPublicKeyPEM: peerPublicKeyPEM,
      );
    });
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
      // No pinned key and none presented there is nothing to verify against.
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

  /// Signature material for delivery acknowledgments. Frozen field set.
  String _ackMaterial(Map<String, dynamic> payload) {
    return jsonEncode({
      'msgType': payload['msgType'],
      'ackFor': payload['ackFor'],
      'convId': payload['convId'],
      'senderUuid': payload['senderUuid'],
      'timestamp': payload['timestamp'],
    });
  }

  /// Signature material for signed identity exchanges (audit #1).
  String _identityMaterial(Map<String, dynamic> payload) {
    return jsonEncode({
      'msgType': payload['msgType'],
      'senderUuid': payload['senderUuid'],
      'senderShortId': payload['senderShortId'],
      'senderName': payload['senderName'],
      'senderPublicKeyPEM': payload['senderPublicKeyPEM'],
      'timestamp': payload['timestamp'],
    });
  }

  bool _samePublicKey(String a, String b) {
    return _canonicalPublicKey(a) == _canonicalPublicKey(b);
  }

  String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// Handles a delivery acknowledgment: validates it against this device's
  /// conversation state and upgrades the matching message to `delivered`.
  Future<void> _handleInboundAck(
    Map<String, dynamic> json,
    String peerUuid,
    String myUuid,
  ) async {
    final convId = MessageStore.conversationId(myUuid, peerUuid);
    if (json['convId'] != convId) return; // conversation binding

    final senderUuid = json['senderUuid'] as String? ?? peerUuid;
    if (senderUuid != peerUuid) return; // spoof guard

    final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
    if (timestamp == null) return;
    final age = DateTime.now().difference(timestamp);
    if (age.abs() >
        const Duration(seconds: AhoyConstants.inboundMaxClockSkewSeconds)) {
      return; // freshness
    }

    final ackFor = json['ackFor'] as String? ?? '';
    if (ackFor.isEmpty) return;

    // The ack must reference a message we actually sent to this peer and
    // that is not already delivered unknown ids and replays of acks for
    // messages in other states are ignored (third review #1).
    final stored =
        _msgStore.loadMessages(convId).where((m) => m.id == ackFor).firstOrNull;
    if (stored == null ||
        (stored.status != MessageStatus.sent &&
            stored.status != MessageStatus.delivered)) {
      ahoyLog('[ChatService] ignoring ack for unexpected message state');
      return;
    }
    if (stored.status == MessageStatus.delivered) return; // idempotent

    // The ack is only trusted when it is signed with the peer key pinned for
    // this conversation otherwise ignore it silently.
    final pinnedKey = _findConversation(convId)?.peerPublicKeyPEM;
    if (pinnedKey == null || pinnedKey.isEmpty) return;
    final signature = json['signature'] as String? ?? '';
    if (!_crypto.verifyPayloadSignature(
      _ackMaterial(json),
      signature,
      pinnedKey,
    )) {
      ahoyLog('[ChatService] dropping ack with invalid signature');
      return;
    }

    if (stored.status == MessageStatus.delivered) return; // idempotent

    await _msgStore.updateMessageStatus(convId, ackFor, MessageStatus.delivered);
  }

  /// Sends a sealed, signed acknowledgment for a stored inbound message.
  /// Best-effort: failures are logged and never affect message delivery.
  Future<void> _sendAck({
    required String convId,
    required String ackFor,
    required String? senderKey,
    required String myUuid,
    required String peerUuid,
  }) async {
    if (senderKey == null || senderKey.isEmpty || !_crypto.isReady) return;
    try {
      final inner = <String, dynamic>{
        'msgType': 'ack',
        'ackFor': ackFor,
        'convId': convId,
        'senderUuid': myUuid,
        'timestamp': DateTime.now().toIso8601String(),
      };
      inner['signature'] = _crypto.signPayload(_ackMaterial(inner));
      final payload = {
        'v': 3,
        'ct': _crypto.encryptForPeer(jsonEncode(inner), senderKey),
      };
      final sent = await _transport.send(peerUuid, myUuid, '', '', payload);
      if (!sent) ahoyLog('[ChatService] ack send failed');
    } catch (e) {
      ahoyLog('[ChatService] ack failed', e);
    }
  }

  /// Handles a signed identity exchange (audit #1): registers the peer's
  /// verified key, replies with our own identity once, and unblocks any
  /// queued sends that were waiting for this key.
  Future<void> _handleInboundIdentity(
    Map<String, dynamic> json,
    String peerUuid,
    String myUuid, {
    String? myShortId,
    String? myDisplayName,
    String? myPublicKeyPEM,
  }) async {
    final senderUuid = json['senderUuid'] as String? ?? '';
    if (senderUuid != peerUuid) return; // spoof guard

    final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
    if (timestamp == null) return;
    final age = DateTime.now().difference(timestamp);
    if (age.abs() >
        const Duration(seconds: AhoyConstants.inboundMaxClockSkewSeconds)) {
      return; // freshness
    }

    final pem = json['senderPublicKeyPEM'] as String?;
    if (pem == null || pem.isEmpty) return;
    final signature = json['signature'] as String? ?? '';
    if (!_crypto.verifyPayloadSignature(_identityMaterial(json), signature, pem)) {
      ahoyLog('[ChatService] dropping identity with invalid signature');
      return;
    }

    registerVerifiedPeerKey(senderUuid, pem);

    // Reply once so the peer can pin us too the reply is itself a signed
    // identity, so this cannot loop.
    if (!_identityRepliedTo.contains(peerUuid) && myPublicKeyPEM != null) {
      _identityRepliedTo.add(peerUuid);
      await _sendIdentity(
        peerUuid: peerUuid,
        myUuid: myUuid,
        myShortId: myShortId,
        myDisplayName: myDisplayName,
        myPublicKeyPEM: myPublicKeyPEM,
      );
    }

    // The newly learned key may unblock queued messages.
    if (hasPendingFor(peerUuid)) {
      await retryPendingFor(peerUuid);
    }
  }

  /// Broadcasts our signed identity to a peer (throttled per peer).
  Future<void> _sendIdentity({
    required String peerUuid,
    required String myUuid,
    String? myShortId,
    String? myDisplayName,
    String? myPublicKeyPEM,
  }) async {
    final now = DateTime.now();
    final last = _identitySentAt[peerUuid];
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _identitySentAt[peerUuid] = now;

    if (myPublicKeyPEM == null || !_crypto.isReady) return;
    final payload = _buildIdentityPayload(
      myUuid: myUuid,
      myShortId: myShortId ?? '',
      myDisplayName: myDisplayName ?? '',
      myPublicKeyPEM: myPublicKeyPEM,
    );
    await _transport.send(peerUuid, myUuid, '', '', payload);
  }

  Map<String, dynamic> _buildIdentityPayload({
    required String myUuid,
    required String myShortId,
    required String myDisplayName,
    required String myPublicKeyPEM,
  }) {
    final payload = <String, dynamic>{
      'msgType': 'identity',
      'senderUuid': myUuid,
      'senderShortId': myShortId,
      'senderName': myDisplayName,
      'senderPublicKeyPEM': myPublicKeyPEM,
      'timestamp': DateTime.now().toIso8601String(),
    };
    payload['signature'] = _crypto.signPayload(_identityMaterial(payload));
    return payload;
  }

  String _canonicalPublicKey(String key) {
    return key.replaceAll(_pemWhitespace, '');
  }
}

/// A text message queued for retry after a failed transport send (audit M-3).
/// Media retries carry the prepared wire bytes so they never depend on a
/// source file that may already have been deleted (audit H-1).
class _PendingSend {
  final String msgId;
  final String convId;
  final String peerUuid;
  final String peerDisplayName;
  final String peerShortId;
  final MessageType type;
  final String content;
  final String? mediaBase64;
  final String? replyToId;
  final String? replyToPreview;

  // Sender identity captured at enqueue time retries rebuild the payload
  // with these plus a fresh timestamp.
  final String myUuid;
  final String myShortId;
  final String myDisplayName;
  final String? myPublicKeyPEM;
  final String? peerPublicKeyPEM;

  int attempts = 0;

  _PendingSend({
    required this.msgId,
    required this.convId,
    required this.peerUuid,
    required this.peerDisplayName,
    required this.peerShortId,
    required this.type,
    required this.content,
    required this.mediaBase64,
    required this.replyToId,
    required this.replyToPreview,
    required this.myUuid,
    required this.myShortId,
    required this.myDisplayName,
    required this.myPublicKeyPEM,
    required this.peerPublicKeyPEM,
  });
}

/// Media prepared for one send: the encrypted-at-rest path stored locally and
/// the base64 content that rides inside the sealed payload.
typedef _PreparedMedia = ({String stored, String wire});
