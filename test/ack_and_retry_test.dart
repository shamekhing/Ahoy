import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/core/errors.dart';
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

const _aliceUuid = '11111111-1111-4111-8111-111111111111';
const _bobUuid = '22222222-2222-4222-8222-222222222222';
const _malloryUuid = '33333333-3333-4333-8333-333333333333';
const _msgId = 'aaaaaaaa-1111-2222-3333-444444444444';

String _wire(Map<String, dynamic> data, String fromUuid) =>
    jsonEncode({...data, 'from': fromUuid});

String _ackMaterial(Map<String, dynamic> p) {
  final material = jsonEncode({
    'msgType': p['msgType'],
    'ackFor': p['ackFor'],
    'convId': p['convId'],
    'senderUuid': p['senderUuid'],
    'timestamp': p['timestamp'],
  });
  return 'ahoy-ack-v1:$material';
}

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

class _FlakyTransportManager extends TransportManager {
  _FlakyTransportManager({required this.alwaysFails});
  final bool alwaysFails;
  bool _nextFails = true;

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
    if (alwaysFails) return false;
    if (_nextFails) {
      _nextFails = false;
      return false;
    }
    return true;
  }
}

class _Harness<T extends TransportManager> {
  final ChatService service;
  final T transport;
  final ConversationStore convStore;
  final MessageStore msgStore;

  _Harness(this.service, this.transport, this.convStore, this.msgStore);
}

Future<PrefsStore> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  return prefs;
}

Future<(CryptoService, Map<String, String>)> _identity() async {
  final crypto = CryptoService();
  final keys = await crypto.generateKeyPair();
  crypto.activate(keys['privateKey']!, keys['publicKey']!);
  return (crypto, keys);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('inbound messages are acked and senders upgrade to delivered', () async {
    final (alice, aliceKeys) = await _identity();
    final (bob, bobKeys) = await _identity();
    final alicePrefs = await _prefs();
    final bobPrefs = await _prefs();
    final aliceTransport = _CapturingTransportManager();
    final bobTransport = _CapturingTransportManager();
    final aliceConv = ConversationStore(alicePrefs, _localCrypto);
    final aliceMsg = MessageStore(alicePrefs, _localCrypto);
    final bobConv = ConversationStore(bobPrefs, _localCrypto);
    final bobMsg = MessageStore(bobPrefs, _localCrypto);
    final aliceH = _Harness(
      ChatService(aliceTransport, aliceConv, aliceMsg, alice, _localCrypto),
      aliceTransport,
      aliceConv,
      aliceMsg,
    );
    final bobH = _Harness(
      ChatService(bobTransport, bobConv, bobMsg, bob, _localCrypto),
      bobTransport,
      bobConv,
      bobMsg,
    );

    await aliceH.service.sendMessage(
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

    final inbound = await bobH.service.onInboundPacket(
      rawPayload: _wire(aliceH.transport.lastData!, _aliceUuid),
      peerUuid: _aliceUuid,
      peerShortId: '',
      peerDisplayName: 'Unknown',
      myUuid: _bobUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );
    expect(inbound, isNotNull);

    // Bob's transport captured the sealed ack (no plaintext ack fields).
    final ack = bobH.transport.lastData!;
    expect(ack['v'], 3);
    expect(ack['ct'], isNotEmpty);
    expect(ack.containsKey('ackFor'), isFalse);

    // Alice processes the ack her message upgrades to delivered.
    await aliceH.service.onInboundPacket(
      rawPayload: _wire(ack, _bobUuid),
      peerUuid: _bobUuid,
      peerShortId: 'BOBBB1',
      peerDisplayName: 'Bob',
      myUuid: _aliceUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    final stored = aliceH.msgStore
        .loadMessages(MessageStore.conversationId(_aliceUuid, _bobUuid))
        .single;
    expect(stored.status, MessageStatus.delivered);
  });

  test('acks bound to another conversation are ignored', () async {
    final (alice, aliceKeys) = await _identity();
    final (bob, _) = await _identity();
    final alicePrefs = await _prefs();
    final aliceTransport = _CapturingTransportManager();
    final aliceConv = ConversationStore(alicePrefs, _localCrypto);
    final aliceMsg = MessageStore(alicePrefs, _localCrypto);
    final aliceH = _Harness(
      ChatService(aliceTransport, aliceConv, aliceMsg, alice, _localCrypto),
      aliceTransport,
      aliceConv,
      aliceMsg,
    );

    // Alice sends to Bob so a conversation with Bob's pinned key exists and
    // the message is in `sent` state.
    final (_, bobKeys) = await _identity();
    await aliceH.service.sendMessage(
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

    // Bob (or anyone) sends an ack bound to a different conversation.
    final inner = <String, dynamic>{
      'msgType': 'ack',
      'ackFor': _msgId,
      'convId': MessageStore.conversationId(_bobUuid, _malloryUuid),
      'senderUuid': _bobUuid,
      'timestamp': DateTime.now().toIso8601String(),
    };
    inner['signature'] = bob.signPayload(_ackMaterial(inner));
    final sealed = {
      'v': 3,
      'ct': alice.encryptForPeer(jsonEncode(inner), aliceKeys['publicKey']!),
    };

    await aliceH.service.onInboundPacket(
      rawPayload: _wire(sealed, _bobUuid),
      peerUuid: _bobUuid,
      peerShortId: 'BOBBB1',
      peerDisplayName: 'Bob',
      myUuid: _aliceUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    final stored = aliceH.msgStore
        .loadMessages(MessageStore.conversationId(_aliceUuid, _bobUuid))
        .single;
    expect(stored.status, MessageStatus.sent);
  });

  test('acks from a non-pinned sender are ignored', () async {
    final (alice, aliceKeys) = await _identity();
    final (_, bobKeys) = await _identity();
    final (mallory, _) = await _identity();
    final alicePrefs = await _prefs();
    final aliceTransport = _CapturingTransportManager();
    final aliceConv = ConversationStore(alicePrefs, _localCrypto);
    final aliceMsg = MessageStore(alicePrefs, _localCrypto);
    final aliceH = _Harness(
      ChatService(aliceTransport, aliceConv, aliceMsg, alice, _localCrypto),
      aliceTransport,
      aliceConv,
      aliceMsg,
    );

    await aliceH.service.sendMessage(
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

    // Mallory signs the ack, but the wire claims Bob sent it. Alice verifies
    // against Bob's pinned key the forgery fails.
    final inner = <String, dynamic>{
      'msgType': 'ack',
      'ackFor': _msgId,
      'convId': MessageStore.conversationId(_aliceUuid, _bobUuid),
      'senderUuid': _bobUuid,
      'timestamp': DateTime.now().toIso8601String(),
    };
    inner['signature'] = mallory.signPayload(_ackMaterial(inner));
    final sealed = {
      'v': 3,
      'ct': alice.encryptForPeer(jsonEncode(inner), aliceKeys['publicKey']!),
    };

    await aliceH.service.onInboundPacket(
      rawPayload: _wire(sealed, _bobUuid),
      peerUuid: _bobUuid,
      peerShortId: 'BOBBB1',
      peerDisplayName: 'Bob',
      myUuid: _aliceUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    final stored = aliceH.msgStore
        .loadMessages(MessageStore.conversationId(_aliceUuid, _bobUuid))
        .single;
    expect(stored.status, MessageStatus.sent);
  });

  test('failed sends are retried when the peer returns', () async {
    final (alice, aliceKeys) = await _identity();
    final (_, bobKeys) = await _identity();
    final alicePrefs = await _prefs();
    final tm = _FlakyTransportManager(alwaysFails: false);
    final aliceConv = ConversationStore(alicePrefs, _localCrypto);
    final aliceMsg = MessageStore(alicePrefs, _localCrypto);
    final aliceH = _Harness(
      ChatService(tm, aliceConv, aliceMsg, alice, _localCrypto),
      tm,
      aliceConv,
      aliceMsg,
    );

    await aliceH.service.sendMessage(
      myUuid: _aliceUuid,
      myShortId: 'ALICE1',
      myDisplayName: 'Alice',
      peerUuid: _bobUuid,
      peerDisplayName: 'Bob',
      peerShortId: 'BOBBB1',
      type: MessageType.text,
      content: 'retry me',
      myPublicKeyPEM: aliceKeys['publicKey'],
      peerPublicKeyPEM: bobKeys['publicKey'],
    );

    final convId = MessageStore.conversationId(_aliceUuid, _bobUuid);
    expect(
      aliceH.msgStore.loadMessages(convId).single.status,
      MessageStatus.failed,
    );
    expect(aliceH.service.hasPendingFor(_bobUuid), isTrue);

    final touched = await aliceH.service.retryPendingFor(_bobUuid);
    expect(touched, [convId]);
    expect(aliceH.service.hasPendingFor(_bobUuid), isFalse);
    expect(
      aliceH.msgStore.loadMessages(convId).single.status,
      MessageStatus.sent,
    );
  });

  test('retries stop after the maximum number of attempts', () async {
    final (alice, aliceKeys) = await _identity();
    final (_, bobKeys) = await _identity();
    final alicePrefs = await _prefs();
    final tm = _FlakyTransportManager(alwaysFails: true);
    final aliceConv = ConversationStore(alicePrefs, _localCrypto);
    final aliceMsg = MessageStore(alicePrefs, _localCrypto);
    final aliceH = _Harness(
      ChatService(tm, aliceConv, aliceMsg, alice, _localCrypto),
      tm,
      aliceConv,
      aliceMsg,
    );

    await aliceH.service.sendMessage(
      myUuid: _aliceUuid,
      myShortId: 'ALICE1',
      myDisplayName: 'Alice',
      peerUuid: _bobUuid,
      peerDisplayName: 'Bob',
      peerShortId: 'BOBBB1',
      type: MessageType.text,
      content: 'retry me',
      myPublicKeyPEM: aliceKeys['publicKey'],
      peerPublicKeyPEM: bobKeys['publicKey'],
    );

    final convId = MessageStore.conversationId(_aliceUuid, _bobUuid);
    await aliceH.service.retryPendingFor(_bobUuid);
    await aliceH.service.retryPendingFor(_bobUuid);
    expect(aliceH.service.hasPendingFor(_bobUuid), isTrue);
    await aliceH.service.retryPendingFor(_bobUuid);

    expect(aliceH.service.hasPendingFor(_bobUuid), isFalse);
    expect(
      aliceH.msgStore.loadMessages(convId).single.status,
      MessageStatus.failed,
    );
  });

  test('acks for unknown or non-sent messages are ignored (review #1)', () async {
    final (alice, aliceKeys) = await _identity();
    final (bob, bobKeys) = await _identity();
    final alicePrefs = await _prefs();
    final tm = _FlakyTransportManager(alwaysFails: false);
    final aliceConv = ConversationStore(alicePrefs, _localCrypto);
    final aliceMsg = MessageStore(alicePrefs, _localCrypto);
    final aliceH = _Harness(
      ChatService(tm, aliceConv, aliceMsg, alice, _localCrypto),
      tm,
      aliceConv,
      aliceMsg,
    );

    // The first send fails, so the message exists with status `failed`.
    await aliceH.service.sendMessage(
      myUuid: _aliceUuid,
      myShortId: 'ALICE1',
      myDisplayName: 'Alice',
      peerUuid: _bobUuid,
      peerDisplayName: 'Bob',
      peerShortId: 'BOBBB1',
      type: MessageType.text,
      content: 'hello',
      myPublicKeyPEM: aliceKeys['publicKey'],
      peerPublicKeyPEM: bobKeys['publicKey'],
    );
    final convId = MessageStore.conversationId(_aliceUuid, _bobUuid);
    final failedMsg = aliceH.msgStore.loadMessages(convId).single;
    expect(failedMsg.status, MessageStatus.failed);

    Map<String, dynamic> sealedAckFor(String msgId) {
      final inner = <String, dynamic>{
        'msgType': 'ack',
        'ackFor': msgId,
        'convId': convId,
        'senderUuid': _bobUuid,
        'timestamp': DateTime.now().toIso8601String(),
      };
      inner['signature'] = bob.signPayload(_ackMaterial(inner));
      return {
        'v': 3,
        'ct': alice.encryptForPeer(jsonEncode(inner), aliceKeys['publicKey']!),
      };
    }

    Future<void> deliverAck(String msgId) async {
      await aliceH.service.onInboundPacket(
        rawPayload: _wire(sealedAckFor(msgId), _bobUuid),
        peerUuid: _bobUuid,
        peerShortId: 'BOBBB1',
        peerDisplayName: 'Bob',
        myUuid: _aliceUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );
    }

    // A validly signed ack for a FAILED message must not flip it.
    await deliverAck(failedMsg.id);
    expect(
      aliceH.msgStore.loadMessages(convId).single.status,
      MessageStatus.failed,
    );

    // A validly signed ack for an unknown id must be ignored too.
    await deliverAck('ffffffff-1111-2222-3333-444444444444');
    expect(
      aliceH.msgStore.loadMessages(convId).single.status,
      MessageStatus.failed,
    );
  });

  test('blocked peers are rejected on the sending path (review #4)', () async {
    final (alice, aliceKeys) = await _identity();
    final (_, bobKeys) = await _identity();
    final alicePrefs = await _prefs();
    final tm = _CapturingTransportManager();
    final aliceConv = ConversationStore(alicePrefs, _localCrypto);
    final aliceMsg = MessageStore(alicePrefs, _localCrypto);
    final aliceH = _Harness(
      ChatService(tm, aliceConv, aliceMsg, alice, _localCrypto),
      tm,
      aliceConv,
      aliceMsg,
    );
    aliceH.service.attachBlockedPeers({_bobUuid});

    expect(
      () => aliceH.service.sendMessage(
        myUuid: _aliceUuid,
        myShortId: 'ALICE1',
        myDisplayName: 'Alice',
        peerUuid: _bobUuid,
        peerDisplayName: 'Bob',
        peerShortId: 'BOBBB1',
        type: MessageType.text,
        content: 'hello',
        myPublicKeyPEM: aliceKeys['publicKey'],
        peerPublicKeyPEM: bobKeys['publicKey'],
      ),
      throwsA(isA<TransportError>()),
    );
  });
}