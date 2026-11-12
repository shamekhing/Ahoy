import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/providers/chat_provider.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport/ble_transport.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerRealUuid = '22222222-2222-4222-8222-222222222222';
const _peerMac = 'AA:BB:CC:DD:EE:FF';

class _CapturingTransportManager extends TransportManager {
  final List<Map<String, dynamic>> sends = [];

  @override
  TransportMode currentModeFor(String peerUuid) => TransportMode.ble;

  @override
  Future<bool> send(
    String peerUuid,
    String fromUuid,
    String fromShortId,
    String fromName,
    Map<String, dynamic> data,
  ) async {
    sends.add({'peerUuid': peerUuid, 'data': data});
    return true;
  }
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

String _chatV3Material(Map<String, dynamic> payload) {
  return 'ahoy-chat-v3:${jsonEncode({
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
  })}';
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

Map<String, dynamic> _signedIdentityPayload(
  CryptoService peer,
  String peerPublicKeyPEM,
) {
  final payload = <String, dynamic>{
    'msgType': 'identity',
    'senderUuid': _peerRealUuid,
    'senderShortId': 'PEER12',
    'senderName': 'Peer',
    'senderPublicKeyPEM': peerPublicKeyPEM,
    'timestamp': DateTime.now().toIso8601String(),
  };
  payload['signature'] = peer.signPayload(_identityMaterial(payload));
  return payload;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'inbound BLE packet binds the transport id to the canonical UUID',
    () async {
      final transport = TransportManager();
      transport.debugEmitPacket(
        InboundPacket(
          peerUuid: _peerRealUuid,
          peerShortId: 'PEER12',
          peerDisplayName: 'Peer',
          payload: '{}',
          transport: TransportMode.ble,
          transportPeerId: _peerMac,
        ),
      );

      expect(transport.canonicalUuid(_peerMac), _peerRealUuid);
      expect(transport.tempIdFor(_peerRealUuid), _peerMac);
      expect(transport.currentModeFor(_peerRealUuid), TransportMode.ble);
      expect(transport.currentModeFor(_peerMac), TransportMode.ble);
    },
  );

  test('ble transport learns the device behind a canonical UUID', () async {
    final ble = BleTransport();
    final inner = jsonEncode({
      'from': _peerRealUuid,
      'fromShortId': 'PEER12',
      'fromName': 'Peer',
    });
    final chunk = jsonEncode({
      'm': 'aaaaaaaa-1111-2222-3333-444444444444',
      'seq': 0,
      'total': 1,
      'data': base64.encode(utf8.encode(inner)),
    });

    ble.debugReceiveChunk(chunk, _peerMac);

    expect(ble.debugUuidToDevice[_peerRealUuid], _peerMac);
    expect(ble.debugResolvedDeviceAddress(_peerRealUuid), _peerMac);
    // The raw device address still resolves to itself.
    expect(ble.debugResolvedDeviceAddress(_peerMac), _peerMac);
  });

  test(
    'a pure BLE first contact rekeys the conversation and outbox to the '
    'canonical UUID and the queued message delivers',
    () async {
      final (myCrypto, myKeys) = await _identity();
      final (peerCrypto, peerKeys) = await _identity();

      final prefs = await _prefs();
      final convStore = ConversationStore(prefs);
      final msgStore = MessageStore(prefs);
      final transport = _CapturingTransportManager();
      final service = ChatService(transport, convStore, msgStore, myCrypto);

      // 1. The user messages a BLE scan-response peer: no key is known, so
      // only the signed identity goes out and the message queues under the
      // temporary id.
      await service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerMac,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'hello',
        myPublicKeyPEM: myKeys['publicKey'],
      );
      final tempConvId = MessageStore.conversationId(_myUuid, _peerMac);
      expect(convStore.loadAll().single.id, tempConvId);
      expect(service.hasPendingFor(_peerMac), isTrue);
      expect(transport.sends, hasLength(1));

      // 2. The peer's signed identity arrives over BLE: the transport binds
      // the MAC to the canonical UUID before the chat layer sees it.
      final identityJson = jsonEncode(
        _signedIdentityPayload(peerCrypto, peerKeys['publicKey']!),
      );
      transport.debugEmitPacket(
        InboundPacket(
          peerUuid: _peerRealUuid,
          peerShortId: 'PEER12',
          peerDisplayName: 'Peer',
          payload: identityJson,
          transport: TransportMode.ble,
          transportPeerId: _peerMac,
        ),
      );

      // 3. The identity is processed: state is rebound to the canonical key,
      // the identity reply goes out, and the queued message retries sealed
      // to the now-verified key.
      final inbound = await service.onInboundPacket(
        rawPayload: identityJson,
        peerUuid: _peerRealUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        myPublicKeyPEM: myKeys['publicKey'],
        transport: TransportMode.ble,
        receiveOff: false,
        blockedUuids: const {},
      );
      expect(inbound, isNull, reason: 'identity packets store no message');

      final canonicalConvId =
          MessageStore.conversationId(_myUuid, _peerRealUuid);
      final conversations = convStore.loadAll();
      expect(conversations, hasLength(1), reason: 'no duplicate thread');
      expect(conversations.single.id, canonicalConvId);
      expect(conversations.single.peerUuid, _peerRealUuid);

      expect(service.hasPendingFor(_peerMac), isFalse);
      expect(service.hasPendingFor(_peerRealUuid), isFalse);

      // Sends so far: identity, identity reply, sealed retry.
      expect(transport.sends, hasLength(3));
      final retry = transport.sends.last;
      expect(retry['peerUuid'], _peerRealUuid);
      final sealed = retry['data'] as Map<String, dynamic>;
      expect(sealed['v'], 3);
      // Sealed to the peer's key: only the peer can open it.
      final inner =
          jsonDecode(peerCrypto.decryptFromPeer(sealed['ct'] as String))
              as Map<String, dynamic>;
      expect(inner['msgType'], 'chat');
      expect(inner['convId'], canonicalConvId);
      expect(inner['senderUuid'], _myUuid);
      expect(inner['content'], 'hello');

      final messages = msgStore.loadMessages(canonicalConvId);
      expect(messages, hasLength(1));
      expect(messages.single.status, MessageStatus.sent);
    },
  );

  test(
    'a sealed chat message after the rekey lands in the same thread',
    () async {
      final (myCrypto, myKeys) = await _identity();
      final (peerCrypto, peerKeys) = await _identity();

      final prefs = await _prefs();
      final convStore = ConversationStore(prefs);
      final msgStore = MessageStore(prefs);
      final transport = _CapturingTransportManager();
      final service = ChatService(transport, convStore, msgStore, myCrypto);

      await service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerMac,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'hello',
        myPublicKeyPEM: myKeys['publicKey'],
      );

      final identityJson = jsonEncode(
        _signedIdentityPayload(peerCrypto, peerKeys['publicKey']!),
      );
      transport.debugEmitPacket(
        InboundPacket(
          peerUuid: _peerRealUuid,
          peerShortId: 'PEER12',
          peerDisplayName: 'Peer',
          payload: identityJson,
          transport: TransportMode.ble,
          transportPeerId: _peerMac,
        ),
      );
      await service.onInboundPacket(
        rawPayload: identityJson,
        peerUuid: _peerRealUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        myPublicKeyPEM: myKeys['publicKey'],
        transport: TransportMode.ble,
        receiveOff: false,
        blockedUuids: const {},
      );

      final canonicalConvId =
          MessageStore.conversationId(_myUuid, _peerRealUuid);
      final innerPayload = <String, dynamic>{
        'msgType': 'chat',
        'msgId': 'bbbbbbbb-1111-2222-3333-444444444444',
        'convId': canonicalConvId,
        'senderUuid': _peerRealUuid,
        'senderShortId': 'PEER12',
        'senderName': 'Peer',
        'type': 'text',
        'content': 'hi there',
        'replyToId': null,
        'replyToPreview': null,
        'timestamp': DateTime.now().toIso8601String(),
        'senderPublicKeyPEM': peerKeys['publicKey'],
      };
      innerPayload['signature'] =
          peerCrypto.signPayload(_chatV3Material(innerPayload));
      final chatJson = jsonEncode({
        'v': 3,
        'ct': peerCrypto.encryptForPeer(
          jsonEncode(innerPayload),
          myKeys['publicKey']!,
        ),
      });
      final received = await service.onInboundPacket(
        rawPayload: chatJson,
        peerUuid: _peerRealUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        myPublicKeyPEM: myKeys['publicKey'],
        transport: TransportMode.ble,
        receiveOff: false,
        blockedUuids: const {},
      );
      expect(received, isNotNull);
      expect(received!.conversationId, canonicalConvId);
      expect(convStore.loadAll(), hasLength(1));
      expect(msgStore.loadMessages(canonicalConvId), hasLength(2));
      expect(
        service.peerTrust(_peerRealUuid)?.state.name,
        'pinned',
        reason: 'the peer signed an accepted message',
      );
    },
  );

  test('the retry trigger canonicalizes the announcement id', () async {
    final (myCrypto, myKeys) = await _identity();
    final (peerCrypto, peerKeys) = await _identity();

    final prefs = await _prefs();
    final convStore = ConversationStore(prefs);
    final msgStore = MessageStore(prefs);
    final transport = _CapturingTransportManager();
    final service = ChatService(transport, convStore, msgStore, myCrypto);
    final provider = ChatProvider(service, convStore, msgStore, transport);

    await service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerMac,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.text,
      content: 'hello',
      myPublicKeyPEM: myKeys['publicKey'],
    );

    // With no key for the peer yet, the retry attempt fails closed and the
    // entry stays queued.
    transport.sends.clear();
    provider.maybeRetryFor(_peerMac);
    await pumpEventQueue();
    expect(transport.sends, isEmpty);
    expect(service.hasPendingFor(_peerMac), isTrue);

    // After the alias is learned and the peer's verified key registered, the
    // trigger keyed by the temporary id still finds the outbox through the
    // canonical resolution, and the payload is sealed to the verified key.
    transport.registerAlias(tempId: _peerMac, canonicalId: _peerRealUuid);
    service.registerVerifiedPeerKey(_peerRealUuid, peerKeys['publicKey']!);
    provider.maybeRetryFor(_peerMac);
    await pumpEventQueue();
    expect(transport.sends, hasLength(1));
    expect(transport.sends.single['peerUuid'], _peerRealUuid);
    final sealed = transport.sends.single['data'] as Map<String, dynamic>;
    expect(sealed['v'], 3);
    final inner =
        jsonDecode(peerCrypto.decryptFromPeer(sealed['ct'] as String))
            as Map<String, dynamic>;
    expect(inner['content'], 'hello');
  });
}
