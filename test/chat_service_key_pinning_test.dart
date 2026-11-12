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
import 'dart:typed_data';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';

// At-rest crypto for stores that now require it (ninth review N-4).
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';
const _keyA =
    '-----BEGIN RSA PUBLIC KEY-----\nKEY_A\n-----END RSA PUBLIC KEY-----';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pins the first peer public key used for a new conversation', () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();

    await harness.service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.text,
      content: 'hello',
      myPublicKeyPEM: harness.myPublicKeyPEM,
      peerPublicKeyPEM: peerKeys['publicKey'],
    );

    final conversation = harness.convStore.loadAll().single;
    expect(conversation.peerPublicKeyPEM, peerKeys['publicKey']);
  });

  test(
    'keeps pinned public key when discovery reports a different key on send',
    () async {
      final harness = await _createHarness();
      final peerCrypto = CryptoService();
      final pinnedKeys = await peerCrypto.generateKeyPair();
      final otherCrypto = CryptoService();
      final otherKeys = await otherCrypto.generateKeyPair();
      await _seedPinnedConversation(
        harness.convStore,
        pinnedKeys['publicKey']!,
      );

      await harness.service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'hello',
        myPublicKeyPEM: harness.myPublicKeyPEM,
        peerPublicKeyPEM: otherKeys['publicKey'],
      );

      final conversation = harness.convStore.loadAll().single;
      expect(conversation.peerPublicKeyPEM, pinnedKeys['publicKey']);
    },
  );

  test(
    'keeps pinned public key when inbound payload advertises a different key',
    () async {
      final harness = await _createHarness();
      await _seedPinnedConversation(harness.convStore, _keyA);

      // A real peer key sealed to us: the pinned placeholder key cannot
      // verify the signature, so the message is rejected and the pin stays.
      final peerCrypto = CryptoService();
      final otherKeys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(otherKeys['privateKey']!, otherKeys['publicKey']!);
      final payload = await _sealedInboundPacket(
        harness,
        peerCrypto,
        senderPublicKeyPEM: otherKeys['publicKey']!,
      );

      await harness.service.onInboundPacket(
        rawPayload: payload,
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
        reason: 'payloads that fail verification are rejected',
      );
    },
  );

  test(
    'drops unsealed unsigned inbound payload for a new conversation',
    () async {
      final harness = await _createHarness();
      final peerCrypto = CryptoService();
      final keys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(keys['privateKey']!, keys['publicKey']!);

      final inner = _innerPayload(senderPublicKeyPEM: keys['publicKey']!);
      // No signature at all.
      final payload = jsonEncode({
        'v': 3,
        'ct': peerCrypto.encryptForPeer(
          jsonEncode(inner),
          harness.myPublicKeyPEM,
        ),
      });

      final message = await harness.service.onInboundPacket(
        rawPayload: payload,
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
    'accepts sealed signed inbound payload and pins the sender public key',
    () async {
      final harness = await _createHarness();
      final peerCrypto = CryptoService();
      final keys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(keys['privateKey']!, keys['publicKey']!);

      final payload = await _sealedInboundPacket(
        harness,
        peerCrypto,
        senderPublicKeyPEM: keys['publicKey']!,
      );

      final message = await harness.service.onInboundPacket(
        rawPayload: payload,
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
  final convStore = ConversationStore(prefs, _localCrypto);
  final msgStore = MessageStore(prefs, _localCrypto);
  final crypto = CryptoService();
  final keys = await crypto.generateKeyPair();
  crypto.activate(keys['privateKey']!, keys['publicKey']!);
  final service = ChatService(
    _FakeTransportManager(),
    convStore,
    msgStore,
    crypto,
    _localCrypto,
  );
  return _Harness(
    convStore: convStore,
    msgStore: msgStore,
    service: service,
    myPublicKeyPEM: keys['publicKey']!,
  );
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

/// Builds a sealed v3 payload signed by [peerCrypto] over the frozen inner
/// field set, addressed to the harness public key.
Future<String> _sealedInboundPacket(
  _Harness harness,
  CryptoService peerCrypto, {
  required String senderPublicKeyPEM,
  String content = 'hello',
  String msgId = 'aaaaaaaa-1111-2222-3333-444444444444',
}) async {
  final inner = _innerPayload(
    senderPublicKeyPEM: senderPublicKeyPEM,
    content: content,
    msgId: msgId,
  );
  inner['signature'] = peerCrypto.signPayload(_signatureMaterialV3(inner));
  return jsonEncode({
    'v': 3,
    'ct': peerCrypto.encryptForPeer(
      jsonEncode(inner),
      harness.myPublicKeyPEM,
    ),
  });
}

Map<String, dynamic> _innerPayload({
  required String senderPublicKeyPEM,
  String content = 'hello',
  String msgId = 'aaaaaaaa-1111-2222-3333-444444444444',
}) {
  return {
    'msgType': 'chat',
    'msgId': msgId,
    'convId': MessageStore.conversationId(_myUuid, _peerUuid),
    'senderUuid': _peerUuid,
    'senderShortId': 'PEER12',
    'senderName': 'Peer',
    'type': MessageType.text.name,
    'content': content,
    'replyToId': null,
    'replyToPreview': null,
    'timestamp': DateTime.now().toIso8601String(),
    'senderPublicKeyPEM': senderPublicKeyPEM,
  };
}

String _signatureMaterialV3(Map<String, dynamic> payload) {
  final material = jsonEncode({
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
  return 'ahoy-chat-v3:$material';
}

class _Harness {
  final ConversationStore convStore;
  final MessageStore msgStore;
  final ChatService service;
  final String myPublicKeyPEM;

  const _Harness({
    required this.convStore,
    required this.msgStore,
    required this.service,
    required this.myPublicKeyPEM,
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
