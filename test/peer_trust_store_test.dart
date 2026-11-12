import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/peer_trust_store.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PeerTrustStore', () {
    test('the first key observed for a UUID wins', () {
      final store = PeerTrustStore();
      final first = store.observe(_peerUuid, 'KEY_A');
      expect(first.state, PeerTrustState.unverified);

      final again = store.observe(_peerUuid, 'KEY_A');
      expect(again.key, 'KEY_A');
      expect(again.pendingKey, isNull);
    });

    test('a conflicting key is recorded as pending and never applied', () {
      final store = PeerTrustStore();
      store.observe(_peerUuid, 'KEY_A');

      final result = store.observe(_peerUuid, 'KEY_B');
      expect(result.key, 'KEY_A');
      expect(result.pendingKey, 'KEY_B');
      expect(store.get(_peerUuid)!.key, 'KEY_A');
      expect(store.keyMatches(_peerUuid, 'KEY_A'), isTrue);
      expect(store.keyMatches(_peerUuid, 'KEY_B'), isFalse);
    });

    test('state transitions: unverified, pinned, safety number', () {
      final store = PeerTrustStore();
      store.observe(_peerUuid, 'KEY_A');
      store.markPinned(_peerUuid);
      expect(store.get(_peerUuid)!.state, PeerTrustState.pinned);
      store.markSafetyNumberVerified(_peerUuid);
      expect(store.get(_peerUuid)!.state, PeerTrustState.verifiedBySafetyNumber);
    });

    test('entries are capped and unverified records evict first', () {
      final store = PeerTrustStore();
      final pinnedUuid = 'aaaaaaaa-1111-4111-8111-111111111111';
      store.observe(pinnedUuid, 'KEY_PINNED');
      store.markPinned(pinnedUuid);
      for (var i = 0; i < PeerTrustStore.maxEntries + 10; i++) {
        store.observe(
          'bbbbbbbb-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          'KEY_$i',
        );
      }
      expect(store.length, PeerTrustStore.maxEntries);
      expect(store.get(pinnedUuid), isNotNull,
          reason: 'pinned records survive eviction of unverified ones');
    });
  });


  group('ChatService identity handling', () {
    test('an identity with a conflicting key is dropped and not answered',
        () async {
      final harness = await _createHarness();
      final peerCrypto = CryptoService();
      final peerKeys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
      expect(
        harness.service.registerVerifiedPeerKey(
          _peerUuid,
          peerKeys['publicKey']!,
        ),
        isTrue,
      );

      final attacker = CryptoService();
      final attackerKeys = await attacker.generateKeyPair();
      attacker.activate(attackerKeys['privateKey']!, attackerKeys['publicKey']!);

      // The real peer announced itself earlier; its key is the known one.
      // Queue a first-contact message via a failing transport so a hijacked
      // identity would otherwise trigger a retry sealed to the attacker key.
      harness.transport.failSends = true;
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
      expect(harness.service.hasPendingFor(_peerUuid), isTrue);
      final sendsAfterQueueing = harness.transport.sent.length;

      final forged = _identityPayload(
        attacker,
        _peerUuid,
        attackerKeys['publicKey']!,
      );
      await harness.service.onInboundPacket(
        rawPayload: jsonEncode(forged),
        peerUuid: _peerUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );

      // No reply to the impostor, no retry triggered, queue intact.
      expect(harness.transport.sent.length, sendsAfterQueueing);
      expect(harness.service.hasPendingFor(_peerUuid), isTrue);
      expect(
        harness.service.registerVerifiedPeerKey(
          _peerUuid,
          attackerKeys['publicKey']!,
        ),
        isFalse,
      );
    });

    test('the genuine identity still unblocks queued sends', () async {
      final harness = await _createHarness();
      final peerCrypto = CryptoService();
      final peerKeys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);

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
        peerPublicKeyPEM: null,
      );

      final genuine = _identityPayload(
        peerCrypto,
        _peerUuid,
        peerKeys['publicKey']!,
      );
      await harness.service.onInboundPacket(
        rawPayload: jsonEncode(genuine),
        peerUuid: _peerUuid,
        peerShortId: 'PEER12',
        peerDisplayName: 'Peer',
        myUuid: _myUuid,
        transport: TransportMode.lan,
        receiveOff: false,
        blockedUuids: const {},
      );

      final chat = harness.transport.sent.where((p) => p['v'] == 3).toList();
      expect(chat, hasLength(1));
      final inner = jsonDecode(
        peerCrypto.decryptFromPeer(chat.single['ct'] as String),
      ) as Map<String, dynamic>;
      expect(inner['content'], 'hello');
    });
  });

  group('DiscoveryProvider to chat wiring', () {
    test('a conflicting announcement hands the original key to chat',
        () async {
      final captured = <String>[];
      final provider = await _createProvider(
        onVerifiedKey: (uuid, pem) => captured.add(pem),
      );
      addTearDown(provider.dispose);

      final peerCrypto = CryptoService();
      final peerKeys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
      final attacker = CryptoService();
      final attackerKeys = await attacker.generateKeyPair();
      attacker.activate(attackerKeys['privateKey']!, attackerKeys['publicKey']!);
      final shortId = CryptoService.shortIdFromUuid(_peerUuid);

      final firstTs = DateTime.now().toIso8601String();
      provider.onAnnouncement(PeerAnnouncement(
        uuid: _peerUuid,
        shortId: shortId,
        displayName: 'Peer',
        publicKeyPEM: peerKeys['publicKey'],
        signature: peerCrypto.signAnnouncement(
          uuid: _peerUuid,
          shortId: shortId,
          displayName: 'Peer',
          publicKeyPEM: peerKeys['publicKey']!,
          timestamp: firstTs,
        ),
        timestamp: firstTs,
        transport: TransportMode.lan,
      ));
      expect(captured, [peerKeys['publicKey']]);

      // A self-signed announcement claiming the same UUID with a different
      // key passes both signature vetoes; DiscoveryService keeps the first
      // key and that is what chat must observe (audit H-2).
      final secondTs = DateTime.now().toIso8601String();
      provider.onAnnouncement(PeerAnnouncement(
        uuid: _peerUuid,
        shortId: shortId,
        displayName: 'Peer',
        publicKeyPEM: attackerKeys['publicKey'],
        signature: attacker.signAnnouncement(
          uuid: _peerUuid,
          shortId: shortId,
          displayName: 'Peer',
          publicKeyPEM: attackerKeys['publicKey']!,
          timestamp: secondTs,
        ),
        timestamp: secondTs,
        transport: TransportMode.lan,
      ));

      expect(captured, [peerKeys['publicKey'], peerKeys['publicKey']],
          reason: 'the refused key must never reach the chat layer');
    });
  });
}

Future<DiscoveryProvider> _createProvider({
  void Function(String uuid, String pem)? onVerifiedKey,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  final provider = DiscoveryProvider(
    DiscoveryService(),
    TransportManager(),
    prefs,
    CryptoService(),
  );
  provider.onVerifiedKey = onVerifiedKey;
  return provider;
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
  final MessageStore msgStore;
  final ChatService service;
  final String myPublicKeyPEM;

  const _Harness({
    required this.transport,
    required this.convStore,
    required this.msgStore,
    required this.service,
    required this.myPublicKeyPEM,
  });
}

Future<_Harness> _createHarness() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  final convStore = ConversationStore(prefs);
  final msgStore = MessageStore(prefs);
  final crypto = CryptoService();
  final keys = await crypto.generateKeyPair();
  crypto.activate(keys['privateKey']!, keys['publicKey']!);
  final transport = _CapturingTransport();
  final service = ChatService(transport, convStore, msgStore, crypto);
  return _Harness(
    transport: transport,
    convStore: convStore,
    msgStore: msgStore,
    service: service,
    myPublicKeyPEM: keys['publicKey']!,
  );
}

class _CapturingTransport extends TransportManager {
  final sent = <Map<String, dynamic>>[];

  /// When true, sends fail so messages land in the retry outbox.
  bool failSends = false;

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
    return !failSends;
  }
}

