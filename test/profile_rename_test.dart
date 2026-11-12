import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/providers/chat_provider.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';

// At-rest crypto for stores that now require it (ninth review N-4).
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a profile rename reaches identity replies (audit L-7)', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final transport = _CapturingTransport();
    final service = ChatService(
      transport,
      ConversationStore(prefs, _localCrypto),
      MessageStore(prefs, _localCrypto),
      crypto,
      _localCrypto,
    );
    final chat = ChatProvider(
      service,
      ConversationStore(prefs, _localCrypto),
      MessageStore(prefs, _localCrypto),
      transport,
    );
    addTearDown(chat.dispose);

    await chat.init(
      myUuid: _myUuid,
      myShortId: 'OLDNAM1',
      myDisplayName: 'Old Name',
      myPublicKeyPEM: keys['publicKey'],
      receiveOff: () => false,
      blockedUuids: const {},
    );

    // The user renames the profile.
    chat.updateMyIdentity(myShortId: 'NEWNAM2', myDisplayName: 'New Name');

    // A peer sends a signed identity; the reply must carry the new name.
    final peer = CryptoService();
    final peerKeys = await peer.generateKeyPair();
    peer.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    final identity = <String, dynamic>{
      'msgType': 'identity',
      'senderUuid': _peerUuid,
      'senderShortId': 'PEER12',
      'senderName': 'Peer',
      'senderPublicKeyPEM': peerKeys['publicKey'],
      'timestamp': DateTime.now().toIso8601String(),
    };
    final identityMaterial = jsonEncode({
      'msgType': identity['msgType'],
      'senderUuid': identity['senderUuid'],
      'senderShortId': identity['senderShortId'],
      'senderName': identity['senderName'],
      'senderPublicKeyPEM': identity['senderPublicKeyPEM'],
      'timestamp': identity['timestamp'],
    });
    identity['signature'] = peer.signPayload('ahoy-identity-v1:$identityMaterial');

    // The peer's signed identity arrives through the provider listener so
    // the reply uses ChatProvider's (renamed) sender identity.
    transport.debugEmitPacket(InboundPacket(
      peerUuid: _peerUuid,
      peerShortId: 'PEER12',
      peerDisplayName: 'Peer',
      payload: jsonEncode(identity),
      transport: TransportMode.lan,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final replies = transport.sent
        .where((p) => p['msgType'] == 'identity')
        .toList();
    expect(replies, hasLength(1));
    expect(replies.single['senderName'], 'New Name');
    expect(replies.single['senderShortId'], 'NEWNAM2');
  });
}
