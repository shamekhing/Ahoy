import 'dart:convert';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/core/enums.dart';
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

/// Spec §6.1: per-peer throttles are rotation-defeatable, so identity
/// processing runs under a global budget (round 8). Rotating UUIDs cannot
/// purchase more RSA verify/reply work than the budget allows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rotating UUIDs cannot exceed the global identity budget', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final crypto = CryptoService();
    final myKeys = await crypto.generateKeyPair();
    crypto.activate(myKeys['privateKey']!, myKeys['publicKey']!);
    final transport = _CapturingTransport();
    final service = ChatService(
      transport,
      ConversationStore(prefs, _localCrypto),
      MessageStore(prefs, _localCrypto),
      crypto,
      _localCrypto,
    );

    final attacker = CryptoService();
    final attackerKeys = await attacker.generateKeyPair();
    attacker.activate(attackerKeys['privateKey']!, attackerKeys['publicKey']!);

    for (var i = 0; i < 50; i++) {
      final uuid =
          '33333333-0000-4000-8000-${i.toString().padLeft(12, '0')}';
      final payload = _identityPayload(
        attacker,
        uuid,
        attackerKeys['publicKey']!,
      );
      await service.onInboundPacket(
        rawPayload: jsonEncode(payload),
        peerUuid: uuid,
        peerShortId: 'ROTATE',
        peerDisplayName: 'Rotate',
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        myPublicKeyPEM: myKeys['publicKey'],
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );
    }

    // Exactly one window's worth of identities was processed: verified,
    // registered, and answered. Everything after the budget was dropped
    // before any RSA work.
    expect(
      service.debugIdentityRepliedCount,
      AhoyConstants.maxIdentityProcessedPerWindow,
    );
    expect(
      service.debugTrustedPeerCount,
      AhoyConstants.maxIdentityProcessedPerWindow,
    );
    expect(transport.sent, hasLength(AhoyConstants.maxIdentityProcessedPerWindow));
  });

  test('a flood from one identity cannot starve the budget for another',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final crypto = CryptoService();
    final myKeys = await crypto.generateKeyPair();
    crypto.activate(myKeys['privateKey']!, myKeys['publicKey']!);
    final transport = _CapturingTransport();
    final service = ChatService(
      transport,
      ConversationStore(prefs, _localCrypto),
      MessageStore(prefs, _localCrypto),
      crypto,
      _localCrypto,
    );

    final flooder = CryptoService();
    final floodKeys = await flooder.generateKeyPair();
    flooder.activate(floodKeys['privateKey']!, floodKeys['publicKey']!);
    const floodUuid = '33333333-0000-4000-8000-000000000000';

    // Far more identity packets than the global budget, all from ONE uuid:
    // the per-peer throttle must stop them without charging the budget
    // (ninth review, spec §6.1).
    for (var i = 0; i < 30; i++) {
      final payload = _identityPayload(
        flooder,
        floodUuid,
        floodKeys['publicKey']!,
      );
      await service.onInboundPacket(
        rawPayload: jsonEncode(payload),
        peerUuid: floodUuid,
        peerShortId: 'FLOOD',
        peerDisplayName: 'Flood',
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        myPublicKeyPEM: myKeys['publicKey'],
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );
    }
    final budgetSpentByFlood = service.debugIdentityRepliedCount;

    // A legitimate peer's identity right after the flood must still be
    // processed: verified, registered and answered.
    final peer = CryptoService();
    final peerKeys = await peer.generateKeyPair();
    peer.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    const peerUuid = '44444444-0000-4000-8000-000000000000';
    final before = transport.sent.length;
    await service.onInboundPacket(
      rawPayload: jsonEncode(
        _identityPayload(peer, peerUuid, peerKeys['publicKey']!),
      ),
      peerUuid: peerUuid,
      peerShortId: 'PEER12',
      peerDisplayName: 'Peer',
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      myPublicKeyPEM: myKeys['publicKey'],
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(
      service.peerTrust(peerUuid),
      isNotNull,
      reason: 'the flood must not consume the global identity budget',
    );
    expect(
      transport.sent.length,
      greaterThan(before),
      reason: 'the identity reply went out',
    );
    expect(
      budgetSpentByFlood,
      lessThanOrEqualTo(1),
      reason: 'the per-peer throttle stopped the flood before the budget',
    );
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
    'senderShortId': 'ROTATE',
    'senderName': 'Rotate',
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
