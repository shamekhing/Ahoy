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

  test('receive off drops identity probes from strangers (audit M-4)',
      () async {
    final harness = await _createHarness();
    final stranger = CryptoService();
    final strangerKeys = await stranger.generateKeyPair();
    stranger.activate(strangerKeys['privateKey']!, strangerKeys['publicKey']!);

    final probe = _identityPayload(
      stranger,
      _peerUuid,
      strangerKeys['publicKey']!,
    );
    await harness.service.onInboundPacket(
      rawPayload: jsonEncode(probe),
      peerUuid: _peerUuid,
      peerShortId: 'PROBE1',
      peerDisplayName: 'Probe',
      myUuid: _myUuid,
      transport: TransportMode.lan,
      receiveOff: true,
      blockedUuids: const {},
    );

    // Nothing was sent back and the probe key was never registered.
    expect(harness.transport.sent, isEmpty);
    expect(harness.service.peerTrust(_peerUuid), isNull);
    expect(
      harness.service.registerVerifiedPeerKey(_peerUuid, 'KEY_UNRELATED'),
      isTrue,
      reason: 'the probe must not have registered any key for the uuid',
    );
  });

  test('receive off still answers identity from a known conversation',
      () async {
    final harness = await _createHarness();
    await harness.convStore.upsert(
      Conversation(
        id: MessageStore.conversationId(_myUuid, _peerUuid),
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026),
      ),
    );

    final peer = CryptoService();
    final peerKeys = await peer.generateKeyPair();
    peer.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);

    final identity = _identityPayload(
      peer,
      _peerUuid,
      peerKeys['publicKey']!,
    );
    await harness.service.onInboundPacket(
      rawPayload: jsonEncode(identity),
      peerUuid: _peerUuid,
      peerShortId: 'PEER12',
      peerDisplayName: 'Peer',
      myUuid: _myUuid,
      transport: TransportMode.lan,
      receiveOff: true,
      blockedUuids: const {},
      myPublicKeyPEM: harness.myPublicKeyPEM,
    );

    // The identity reply went out and the key was registered.
    final replies = harness.transport.sent
        .where((p) => p['msgType'] == 'identity')
        .toList();
    expect(replies, hasLength(1));
    expect(harness.service.peerTrust(_peerUuid)?.key, peerKeys['publicKey']);
  });
}

Map<String, dynamic> _identityPayload(
  CryptoService signer,
  String senderUuid,
  String senderPublicKeyPEM,
) {
  final payload = <String, dynamic>{
    'msgType': 'identity',
    'senderUuid': senderUuid,
    'senderShortId': 'PEER12',
    'senderName': 'Peer',
    'senderPublicKeyPEM': senderPublicKeyPEM,
    'timestamp': DateTime.now().toIso8601String(),
  };
  payload['signature'] = signer.signPayload(_identityMaterial(payload));
  return payload;
}

String _identityMaterial(Map<String, dynamic> payload) {
  return 'ahoy-identity-v1:${jsonEncode({
    'msgType': payload['msgType'],
    'senderUuid': payload['senderUuid'],
    'senderShortId': payload['senderShortId'],
    'senderName': payload['senderName'],
    'senderPublicKeyPEM': payload['senderPublicKeyPEM'],
    'timestamp': payload['timestamp'],
  })}';
}

class _Harness {
  final _CapturingTransport transport;
  final ConversationStore convStore;
  final ChatService service;
  final String myPublicKeyPEM;

  const _Harness({
    required this.transport,
    required this.convStore,
    required this.service,
    required this.myPublicKeyPEM,
  });
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
  final transport = _CapturingTransport();
  final service = ChatService(
    transport,
    convStore,
    msgStore,
    crypto,
    _localCrypto,
  );
  return _Harness(
    transport: transport,
    convStore: convStore,
    service: service,
    myPublicKeyPEM: keys['publicKey']!,
  );
}

class _CapturingTransport extends TransportManager {
  final sent = <Map<String, dynamic>>[];

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
    sent.add(data);
    return true;
  }
}
