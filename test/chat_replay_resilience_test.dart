import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/message.dart';
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
const _strangerUuid = '33333333-3333-4333-8333-333333333333';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a seen-set eviction inside the freshness window admits a replay again',
      () async {
    final harness = await _createHarness();
    // Spec §7 known limit / OPEN #3: the in-memory seen-set holds 512 ids;
    // shrink it so eviction can be reached cheaply. This test documents the
    // documented limit, not an endorsement.
    harness.service.debugSeenMessageIdCap(2);
    final peerCrypto = CryptoService();
    final keys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(keys['privateKey']!, keys['publicKey']!);

    Message? delivered;
    Future<Message?> inbound(String msgId) async {
      final payload = await _sealedInboundPacket(
        harness,
        peerCrypto,
        senderPublicKeyPEM: keys['publicKey']!,
        msgId: msgId,
      );
      return harness.service.onInboundPacket(
        rawPayload: payload,
        peerUuid: _peerUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );
    }

    final convId = MessageStore.conversationId(_myUuid, _peerUuid);
    delivered = await inbound('aaaaaaaa-0000-4000-8000-000000000001');
    expect(delivered, isNotNull);
    delivered = await inbound('aaaaaaaa-0000-4000-8000-000000000002');
    expect(delivered, isNotNull);
    delivered = await inbound('aaaaaaaa-0000-4000-8000-000000000003');
    expect(delivered, isNotNull);

    // msg1 was evicted from the seen-set by msg2/msg3 (cap 2).
    final replayed = await inbound('aaaaaaaa-0000-4000-8000-000000000001');
    // The replay passes the seen-set gate again, but it is state-neutral
    // (round 8, spec §7): the store dedups the row and the conversation's
    // unread counter does not move. The residual cost is one redundant
    // verification and an idempotent ack (OPEN decision #3 remains open to
    // save even that).
    expect(replayed, isNotNull);
    final conversation = harness.convStore.loadAll().single;
    expect(conversation.unreadCount, 3);
    expect(
      harness.msgStore.loadMessages(convId).map((m) => m.id),
      hasLength(3),
    );
  });

  test('a sealed envelope with a swapped routing from is dropped', () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final keys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(keys['privateKey']!, keys['publicKey']!);

    final payload = await _sealedInboundPacket(
      harness,
      peerCrypto,
      senderPublicKeyPEM: keys['publicKey']!,
    );

    // Same sealed bytes, delivered under a stranger's routing UUID: the
    // inner senderUuid no longer equals the routing from (spec §5.1).
    final swapped = await harness.service.onInboundPacket(
      rawPayload: payload,
      peerUuid: _strangerUuid,
      peerShortId: 'STRANGER',
      peerDisplayName: 'Stranger',
      myUuid: _myUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(swapped, isNull);
    expect(harness.convStore.loadAll(), isEmpty);
    expect(
      harness.msgStore
          .loadMessages(MessageStore.conversationId(_myUuid, _strangerUuid)),
      isEmpty,
    );
    expect(
      harness.msgStore
          .loadMessages(MessageStore.conversationId(_myUuid, _peerUuid)),
      isEmpty,
    );
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
