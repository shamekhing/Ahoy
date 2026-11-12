import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/peer_trust_store.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';

// At-rest crypto for stores that now require it (ninth review N-4).
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

const _myUuid = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('identity floods are throttled and session maps stay bounded',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final transport = _CapturingTransport();
    final service = ChatService(
      transport,
      ConversationStore(prefs, _localCrypto),
      MessageStore(prefs, _localCrypto),
      CryptoService(),
      _localCrypto,
    );

    final attacker = CryptoService();
    final attackerKeys = await attacker.generateKeyPair();
    attacker.activate(attackerKeys['privateKey']!, attackerKeys['publicKey']!);

    for (var i = 0; i < 300; i++) {
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
        peerShortId: 'FLOOD1',
        peerDisplayName: 'Flood',
        myUuid: _myUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );
    }

    expect(
      service.debugTrustedPeerCount,
      lessThanOrEqualTo(PeerTrustStore.maxEntries),
    );
    expect(service.debugIdentityRepliedCount, lessThanOrEqualTo(256));
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
    'senderShortId': 'FLOOD1',
    'senderName': 'Flood',
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
