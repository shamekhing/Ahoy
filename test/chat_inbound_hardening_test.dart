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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('inbound messages for a soft-deleted conversation are dropped',
      () async {
    final harness = await _createHarness();
    final convId = MessageStore.conversationId(_myUuid, _peerUuid);
    await harness.convStore.upsert(
      Conversation(
        id: convId,
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026),
      ),
    );
    await harness.convStore.softDelete(convId);

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

    expect(message, isNull);
    expect(harness.msgStore.loadMessages(convId), isEmpty);
  });

  test('oversized inbound media is rejected before the decode cost',
      () async {
    final harness = await _createHarness();
    harness.service.debugMediaLimits(maxBytes: 64);
    final peerCrypto = CryptoService();
    final keys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(keys['privateKey']!, keys['publicKey']!);

    // 900 random-ish bytes -> ~1200 base64 chars, far over the 64-byte cap.
    final media = base64.encode(List.filled(900, 0x61));
    final payload = await _sealedInboundPacket(
      harness,
      peerCrypto,
      senderPublicKeyPEM: keys['publicKey']!,
      type: MessageType.image,
      content: media,
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

    expect(message, isNull);
  });
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

class _FakeTransportManager extends TransportManager {}

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

Future<String> _sealedInboundPacket(
  _Harness harness,
  CryptoService peerCrypto, {
  required String senderPublicKeyPEM,
  String content = 'hello',
  MessageType type = MessageType.text,
  String msgId = 'aaaaaaaa-1111-2222-3333-444444444444',
}) async {
  final inner = {
    'msgType': 'chat',
    'msgId': msgId,
    'convId': MessageStore.conversationId(_myUuid, _peerUuid),
    'senderUuid': _peerUuid,
    'senderShortId': 'PEER12',
    'senderName': 'Peer',
    'type': type.name,
    'content': content,
    'replyToId': null,
    'replyToPreview': null,
    'timestamp': DateTime.now().toIso8601String(),
    'senderPublicKeyPEM': senderPublicKeyPEM,
  };
  inner['signature'] = peerCrypto.signPayload(_signatureMaterialV3(inner));
  return jsonEncode({
    'v': 3,
    'ct': peerCrypto.encryptForPeer(
      jsonEncode(inner),
      harness.myPublicKeyPEM,
    ),
  });
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
