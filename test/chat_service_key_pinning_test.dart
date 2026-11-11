import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';
const _keyA =
    '-----BEGIN RSA PUBLIC KEY-----\nKEY_A\n-----END RSA PUBLIC KEY-----';
const _keyB =
    '-----BEGIN RSA PUBLIC KEY-----\nKEY_B\n-----END RSA PUBLIC KEY-----';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pins the first peer public key used for a new conversation', () async {
    final harness = await _createHarness();

    await harness.service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.text,
      content: 'hello',
      peerPublicKeyPEM: _keyA,
    );

    final conversation = harness.convStore.loadAll().single;
    expect(conversation.peerPublicKeyPEM, _keyA);
  });

  test(
    'keeps pinned public key when discovery reports a different key on send',
    () async {
      final harness = await _createHarness();
      await _seedPinnedConversation(harness.convStore, _keyA);

      await harness.service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'hello',
        peerPublicKeyPEM: _keyB,
      );

      final conversation = harness.convStore.loadAll().single;
      expect(conversation.peerPublicKeyPEM, _keyA);
    },
  );

  test(
    'keeps pinned public key when inbound payload advertises a different key',
    () async {
      final harness = await _createHarness();
      await _seedPinnedConversation(harness.convStore, _keyA);

      await harness.service.onInboundPacket(
        rawPayload: _inboundPacket(senderPublicKeyPEM: _keyB),
        peerUuid: _peerUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );

      final conversation = harness.convStore.loadAll().single;
      expect(conversation.peerPublicKeyPEM, _keyA);
      expect(
        harness.msgStore.loadMessages(conversation.id),
        isEmpty,
        reason: 'unsigned keyed payloads are not accepted',
      );
    },
  );

  test(
    'drops unkeyed unsigned inbound payload for a new conversation',
    () async {
      final harness = await _createHarness();

      final message = await harness.service.onInboundPacket(
        rawPayload: jsonEncode(_inboundPayload()),
        peerUuid: _peerUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );

      expect(message, isNull);
      expect(
        harness.convStore.loadAll(),
        isEmpty,
        reason: 'unauthenticated messages must not create conversations',
      );
      expect(
        harness.msgStore
            .loadMessages(MessageStore.conversationId(_myUuid, _peerUuid)),
        isEmpty,
      );
    },
  );

  test(
    'accepts signed inbound payload and pins the sender public key',
    () async {
      final harness = await _createHarness();
      final peerCrypto = CryptoService();
      final keys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(keys['privateKey']!, keys['publicKey']!);

      final payload = _inboundPayload(senderPublicKeyPEM: keys['publicKey']!);
      payload['signatureVersion'] = 1;
      payload['signature'] = peerCrypto.signPayload(
        _signatureMaterial(payload),
      );

      final message = await harness.service.onInboundPacket(
        rawPayload: jsonEncode(payload),
        peerUuid: _peerUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );

      expect(message, isNotNull);
      final conversation = harness.convStore.loadAll().single;
      expect(conversation.peerPublicKeyPEM, keys['publicKey']);
      expect(harness.msgStore.loadMessages(conversation.id), hasLength(1));
    },
  );
}

Future<_Harness> _createHarness() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  final convStore = ConversationStore(prefs);
  final msgStore = MessageStore(prefs);
  final service = ChatService(
    _FakeTransportManager(),
    convStore,
    msgStore,
    CryptoService(),
  );
  return _Harness(convStore: convStore, msgStore: msgStore, service: service);
}

Future<void> _seedPinnedConversation(ConversationStore convStore, String key) {
  return convStore.upsert(
    Conversation(
      id: MessageStore.conversationId(_myUuid, _peerUuid),
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      peerPublicKeyPEM: key,
      lastTransport: TransportMode.lan,
      createdAt: DateTime.utc(2026),
    ),
  );
}

String _inboundPacket({String? senderPublicKeyPEM}) {
  return jsonEncode(_inboundPayload(senderPublicKeyPEM: senderPublicKeyPEM));
}

Map<String, dynamic> _inboundPayload({String? senderPublicKeyPEM}) {
  return {
    'msgType': 'chat',
    'msgId': 'message-1',
    'convId': MessageStore.conversationId(_myUuid, _peerUuid),
    'senderUuid': _peerUuid,
    'senderShortId': 'PEER12',
    'senderName': 'Peer',
    'type': MessageType.text.name,
    'content': 'hello',
    'isEncrypted': false,
    if (senderPublicKeyPEM != null) 'senderPublicKeyPEM': senderPublicKeyPEM,
    'timestamp': DateTime.now().toIso8601String(),
  };
}

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

class _Harness {
  final ConversationStore convStore;
  final MessageStore msgStore;
  final ChatService service;

  const _Harness({
    required this.convStore,
    required this.msgStore,
    required this.service,
  });
}

class _FakeTransportManager extends TransportManager {
  @override
  TransportMode currentModeFor(String peerUuid) => TransportMode.lan;

  @override
  Future<bool> send(
    String peerUuid,
    String fromUuid,
    String fromShortId,
    String fromName,
    Map<String, dynamic> data,
  ) async {
    return true;
  }
}
