import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _aliceUuid = '11111111-1111-4111-8111-111111111111';
const _bobUuid = '22222222-2222-4222-8222-222222222222';
const _malloryUuid = '33333333-3333-4333-8333-333333333333';
const _validMsgId = 'aaaaaaaa-1111-2222-3333-444444444444';

/// Mirrors TransportManager.send only the routing UUID rides outside.
String _wire(Map<String, dynamic> data, String fromUuid) =>
    jsonEncode({...data, 'from': fromUuid});

/// Mirrors ChatService._signatureMaterial (legacy flat payloads).
String _legacyMaterial(Map<String, dynamic> p) => jsonEncode({
  'msgType': p['msgType'],
  'msgId': p['msgId'],
  'convId': p['convId'],
  'senderUuid': p['senderUuid'],
  'senderShortId': p['senderShortId'],
  'senderName': p['senderName'],
  'type': p['type'],
  'content': p['content'],
  'isEncrypted': p['isEncrypted'],
  'senderPublicKeyPEM': p['senderPublicKeyPEM'],
  'replyToId': p['replyToId'],
  'replyToPreview': p['replyToPreview'],
  'timestamp': p['timestamp'],
});

/// Mirrors ChatService._signatureMaterialV3 (sealed inner payloads).
String _v3Material(Map<String, dynamic> p) => jsonEncode({
  'msgType': p['msgType'],
  'msgId': p['msgId'],
  'convId': p['convId'],
  'senderUuid': p['senderUuid'],
  'senderShortId': p['senderShortId'],
  'senderName': p['senderName'],
  'type': p['type'],
  'content': p['content'],
  'replyToId': p['replyToId'],
  'replyToPreview': p['replyToPreview'],
  'timestamp': p['timestamp'],
  'senderPublicKeyPEM': p['senderPublicKeyPEM'],
});

class _CapturingTransportManager extends TransportManager {
  Map<String, dynamic>? lastData;

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
    lastData = data;
    return true;
  }
}

class _Harness {
  final ChatService service;
  final _CapturingTransportManager transport;
  final ConversationStore convStore;
  final MessageStore msgStore;

  _Harness(this.service, this.transport, this.convStore, this.msgStore);
}

Future<_Harness> _createHarness(CryptoService crypto) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  final convStore = ConversationStore(prefs);
  final msgStore = MessageStore(prefs);
  final transport = _CapturingTransportManager();
  final service = ChatService(transport, convStore, msgStore, crypto);
  return _Harness(service, transport, convStore, msgStore);
}

Future<(CryptoService, Map<String, String>)> _identity() async {
  final crypto = CryptoService();
  final keys = await crypto.generateKeyPair();
  crypto.activate(keys['privateKey']!, keys['publicKey']!);
  return (crypto, keys);
}

Map<String, dynamic> _legacyPayload({
  required CryptoService signer,
  required String publicKeyPEM,
  String? msgId,
  String? convId,
  String? senderUuid,
  DateTime? timestamp,
}) {
  final p = <String, dynamic>{
    'msgType': 'chat',
    'msgId': msgId ?? _validMsgId,
    'convId': convId ?? MessageStore.conversationId(_bobUuid, _aliceUuid),
    'senderUuid': senderUuid ?? _aliceUuid,
    'senderShortId': 'ALICE1',
    'senderName': 'Alice',
    'type': 'text',
    'content': 'hello',
    'isEncrypted': false,
    'senderPublicKeyPEM': publicKeyPEM,
    'replyToId': null,
    'replyToPreview': null,
    'timestamp': (timestamp ?? DateTime.now()).toIso8601String(),
  };
  p['signature'] = signer.signPayload(_legacyMaterial(p));
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sealed v3 round-trip hides metadata and delivers the message', () async {
    final (alice, aliceKeys) = await _identity();
    final (bob, bobKeys) = await _identity();

    final aliceSide = await _createHarness(alice);
    final bobSide = await _createHarness(bob);

    await aliceSide.service.sendMessage(
      myUuid: _aliceUuid,
      myShortId: 'ALICE1',
      myDisplayName: 'Alice',
      peerUuid: _bobUuid,
      peerDisplayName: 'Bob',
      peerShortId: 'BOBBB1',
      type: MessageType.text,
      content: 'hello bob',
      myPublicKeyPEM: aliceKeys['publicKey'],
      peerPublicKeyPEM: bobKeys['publicKey'],
    );

    final data = aliceSide.transport.lastData;
    expect(data, isNotNull);
    expect(data!['v'], 3);
    expect(data['ct'], isNotEmpty);

    // No metadata outside the encrypted blob (audit M-1).
    for (final field in [
      'fromName',
      'fromShortId',
      'timestamp',
      'convId',
      'msgId',
      'content',
      'senderPublicKeyPEM',
    ]) {
      expect(data.containsKey(field), isFalse, reason: field);
    }

    final delivered = await bobSide.service.onInboundPacket(
      rawPayload: _wire(data, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: '',
      peerDisplayName: 'Unknown',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(delivered, isNotNull);
    expect(delivered!.content, 'hello bob');
    expect(delivered.isEncrypted, isTrue);

    // Identity fields come from the signed inner payload, not the wire.
    final conversation = bobSide.convStore.loadAll().single;
    expect(conversation.peerShortId, 'ALICE1');
    expect(conversation.peerDisplayName, 'Alice');
    expect(conversation.peerPublicKeyPEM, aliceKeys['publicKey']);
  });

  test('drops sealed messages whose inner sender does not match the wire', () async {
    final (mallory, malloryKeys) = await _identity();
    final (bob, bobKeys) = await _identity();

    final bobSide = await _createHarness(bob);

    // Mallory seals a message to Bob but the wire claims it came from Alice.
    final inner = <String, dynamic>{
      'msgType': 'chat',
      'msgId': _validMsgId,
      'convId': MessageStore.conversationId(_bobUuid, _aliceUuid),
      'senderUuid': _malloryUuid,
      'senderShortId': 'MALL01',
      'senderName': 'Mallory',
      'type': 'text',
      'content': 'hi',
      'replyToId': null,
      'replyToPreview': null,
      'timestamp': DateTime.now().toIso8601String(),
      'senderPublicKeyPEM': malloryKeys['publicKey'],
    };
    inner['signature'] = mallory.signPayload(_v3Material(inner));
    final ct = bob.encryptForPeer(jsonEncode(inner), bobKeys['publicKey']!);

    final delivered = await bobSide.service.onInboundPacket(
      rawPayload: _wire({'v': 3, 'ct': ct}, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: '',
      peerDisplayName: 'Unknown',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(delivered, isNull);
    expect(bobSide.convStore.loadAll(), isEmpty);
  });

  test('drops messages outside the freshness window (replay)', () async {
    final (alice, aliceKeys) = await _identity();
    final bobSide = await _createHarness(CryptoService());

    final payload = _legacyPayload(
      signer: alice,
      publicKeyPEM: aliceKeys['publicKey']!,
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
    );

    final delivered = await bobSide.service.onInboundPacket(
      rawPayload: _wire(payload, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(delivered, isNull);
    expect(bobSide.convStore.loadAll(), isEmpty);
  });

  test('drops payloads replayed into a different conversation', () async {
    final (alice, aliceKeys) = await _identity();
    final bobSide = await _createHarness(CryptoService());

    // Genuinely signed by Alice but bound to her conversation with Mallory.
    // Replaying it over the wire as "from Alice" must fail the binding.
    final payload = _legacyPayload(
      signer: alice,
      publicKeyPEM: aliceKeys['publicKey']!,
      convId: MessageStore.conversationId(_bobUuid, _malloryUuid),
    );

    final delivered = await bobSide.service.onInboundPacket(
      rawPayload: _wire(payload, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(delivered, isNull);
    expect(bobSide.convStore.loadAll(), isEmpty);
  });

  test('drops messages with invalid msgId', () async {
    final (alice, aliceKeys) = await _identity();
    final bobSide = await _createHarness(CryptoService());

    final payload = _legacyPayload(
      signer: alice,
      publicKeyPEM: aliceKeys['publicKey']!,
      msgId: 'f' * 80,
    );

    final delivered = await bobSide.service.onInboundPacket(
      rawPayload: _wire(payload, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(delivered, isNull);
    expect(bobSide.convStore.loadAll(), isEmpty);
  });

  test('accepts a fresh signed legacy message (receiver-side compat)', () async {
    final (alice, aliceKeys) = await _identity();
    final bobSide = await _createHarness(CryptoService());

    final payload = _legacyPayload(
      signer: alice,
      publicKeyPEM: aliceKeys['publicKey']!,
    );

    final delivered = await bobSide.service.onInboundPacket(
      rawPayload: _wire(payload, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: '',
      peerDisplayName: 'Unknown',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(delivered, isNotNull);
    expect(delivered!.content, 'hello');
    final conversation = bobSide.convStore.loadAll().single;
    expect(conversation.peerShortId, 'ALICE1');
    expect(conversation.peerDisplayName, 'Alice');
  });

  test('keyless first contact exchanges signed identities then seals (audit #1)', () async {
    final (alice, aliceKeys) = await _identity();
    final (bob, bobKeys) = await _identity();
    final aliceSide = await _createHarness(alice);
    final bobSide = await _createHarness(bob);

    // Alice discovered Bob over BLE no key for him yet.
    final queued = await aliceSide.service.sendMessage(
      myUuid: _aliceUuid,
      myShortId: 'ALICE1',
      myDisplayName: 'Alice',
      peerUuid: _bobUuid,
      peerDisplayName: 'Bob',
      peerShortId: 'BOBBB1',
      type: MessageType.text,
      content: 'hello bob',
      myPublicKeyPEM: aliceKeys['publicKey'],
    );
    expect(queued.status, MessageStatus.sending);
    final identity = aliceSide.transport.lastData!;
    expect(identity['msgType'], 'identity');
    expect(identity.containsKey('content'), isFalse);
    expect(identity['senderPublicKeyPEM'], aliceKeys['publicKey']);

    // Bob verifies the identity and replies with his own signed one.
    await bobSide.service.onInboundPacket(
      rawPayload: _wire(identity, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: '',
      peerDisplayName: 'Unknown',
      myUuid: _bobUuid,
      myShortId: 'BOBBB1',
      myDisplayName: 'Bob',
      myPublicKeyPEM: bobKeys['publicKey'],
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    final reply = bobSide.transport.lastData!;
    expect(reply['msgType'], 'identity');
    expect(reply['senderPublicKeyPEM'], bobKeys['publicKey']);

    // Alice processes Bob's identity the queued message is retried sealed.
    await aliceSide.service.onInboundPacket(
      rawPayload: _wire(reply, _bobUuid),
      peerUuid: _bobUuid,
      peerShortId: 'BOBBB1',
      peerDisplayName: 'Bob',
      myUuid: _aliceUuid,
      myShortId: 'ALICE1',
      myDisplayName: 'Alice',
      myPublicKeyPEM: aliceKeys['publicKey'],
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    final sealed = aliceSide.transport.lastData!;
    expect(sealed['v'], 3);

    final delivered = await bobSide.service.onInboundPacket(
      rawPayload: _wire(sealed, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    expect(delivered!.content, 'hello bob');
    expect(delivered.isEncrypted, isTrue);
  });

  test('first contacts must pin the discovery-verified key (audit #7)', () async {
    final (alice, aliceKeys) = await _identity();
    final (mallory, malloryKeys) = await _identity();
    final bobSide = await _createHarness(CryptoService());

    // Bob learned Alice's key from her signed announcement.
    bobSide.service.registerVerifiedPeerKey(_aliceUuid, aliceKeys['publicKey']!);

    // Mallory messages first claiming to be Alice self-consistent key, but
    // it does not match the discovery-verified one.
    final payload = _legacyPayload(
      signer: mallory,
      publicKeyPEM: malloryKeys['publicKey']!,
    );
    final rejected = await bobSide.service.onInboundPacket(
      rawPayload: _wire(payload, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    expect(rejected, isNull);
    expect(bobSide.convStore.loadAll(), isEmpty);

    // The real Alice matching key is accepted.
    final genuine = _legacyPayload(
      signer: alice,
      publicKeyPEM: aliceKeys['publicKey']!,
    );
    final accepted = await bobSide.service.onInboundPacket(
      rawPayload: _wire(genuine, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    expect(accepted, isNotNull);
    expect(bobSide.convStore.loadAll().single.peerPublicKeyPEM,
        aliceKeys['publicKey']);
  });

  test('replays cannot resurrect deleted conversations (review #2)', () async {
    final (alice, aliceKeys) = await _identity();
    final (bob, bobKeys) = await _identity();
    final aliceSide = await _createHarness(alice);
    final bobSide = await _createHarness(bob);

    await aliceSide.service.sendMessage(
      myUuid: _aliceUuid,
      myShortId: 'ALICE1',
      myDisplayName: 'Alice',
      peerUuid: _bobUuid,
      peerDisplayName: 'Bob',
      peerShortId: 'BOBBB1',
      type: MessageType.text,
      content: 'hello bob',
      myPublicKeyPEM: aliceKeys['publicKey'],
      peerPublicKeyPEM: bobKeys['publicKey'],
    );

    final wirePayload = _wire(aliceSide.transport.lastData!, _aliceUuid);
    final first = await bobSide.service.onInboundPacket(
      rawPayload: wirePayload,
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    expect(first, isNotNull);

    // Bob deletes the conversation (messages removed from the store).
    final convId = MessageStore.conversationId(_bobUuid, _aliceUuid);
    await bobSide.convStore.softDelete(convId);
    await bobSide.msgStore.deleteConversationMessages(convId);

    // Replaying the same captured packet within the freshness window must
    // not resurrect anything (third review #2).
    final replayed = await bobSide.service.onInboundPacket(
      rawPayload: wirePayload,
      peerUuid: _aliceUuid,
      peerShortId: 'ALICE1',
      peerDisplayName: 'Alice',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    expect(replayed, isNull);
    expect(bobSide.msgStore.loadMessages(convId), isEmpty);
  });
}