import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _uuid = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a replayed announcement with a stale timestamp is rejected', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final transport = LanTransport(
      discoveryPort: 0,
      messagingPort: 0,
      crypto: crypto,
    );
    await transport.startScanning();
    addTearDown(transport.dispose);
    final port = transport.debugDiscoveryPort!;

    // The attacker captured this announcement an hour ago and replays it.
    final staleTs = DateTime.now().subtract(const Duration(hours: 1));
    final stale = {
      'type': 'ahoy_announce',
      'uuid': _uuid,
      'shortId': CryptoService.shortIdFromUuid(_uuid),
      'displayName': 'Peer',
      'publicKeyPEM': keys['publicKey'],
      'signature': crypto.signAnnouncement(
        uuid: _uuid,
        shortId: CryptoService.shortIdFromUuid(_uuid),
        displayName: 'Peer',
        publicKeyPEM: keys['publicKey']!,
        timestamp: staleTs.toIso8601String(),
      ),
      'timestamp': staleTs.toIso8601String(),
    };

    final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    sock.send(utf8.encode(jsonEncode(stale)), InternetAddress.loopbackIPv4, port);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    sock.close();

    expect(transport.debugPeerConnCount, 0,
        reason: 'a replayed announcement must not create routing state');
  });

  test('a fresh announcement from the same UUID with a different key is refused',
      () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final attacker = CryptoService();
    final attackerKeys = await attacker.generateKeyPair();
    attacker.activate(attackerKeys['privateKey']!, attackerKeys['publicKey']!);
    final transport = LanTransport(
      discoveryPort: 0,
      messagingPort: 0,
      crypto: crypto,
    );
    await transport.startScanning();
    addTearDown(transport.dispose);
    final port = transport.debugDiscoveryPort!;

    Map<String, dynamic> announce(String key, CryptoService signer) {
      final ts = DateTime.now().toIso8601String();
      return {
        'type': 'ahoy_announce',
        'uuid': _uuid,
        'shortId': CryptoService.shortIdFromUuid(_uuid),
        'displayName': 'Peer',
        'publicKeyPEM': key,
        'signature': signer.signAnnouncement(
          uuid: _uuid,
          shortId: CryptoService.shortIdFromUuid(_uuid),
          displayName: 'Peer',
          publicKeyPEM: key,
          timestamp: ts,
        ),
        'timestamp': ts,
      };
    }

    Future<void> send(Map<String, dynamic> json) async {
      final sock =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      sock.send(utf8.encode(jsonEncode(json)), InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sock.close();
    }

    await send(announce(keys['publicKey']!, crypto));
    expect(transport.debugPeerConnCount, 1);
    expect(transport.debugUuidKeys[_uuid], keys['publicKey']);

    // A second node announcing the same UUID with its own key must not steal
    // the route (sixth review, finding 1).
    await send(announce(attackerKeys['publicKey']!, attacker));
    expect(transport.debugPeerConnCount, 1);
    expect(transport.debugUuidKeys[_uuid], keys['publicKey'],
        reason: 'the conflicting key must not replace the first key');
  });

  test('announcement signatures are domain-separated from chat payloads',
      () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final ts = DateTime.now().toIso8601String();

    final announceSignature = crypto.signAnnouncement(
      uuid: _uuid,
      shortId: CryptoService.shortIdFromUuid(_uuid),
      displayName: 'Peer',
      publicKeyPEM: keys['publicKey']!,
      timestamp: ts,
    );

    // The same key must not certify a chat payload shape (sixth review,
    // finding 3): the announcement material carries its own context prefix.
    final chatMaterial = jsonEncode({
      'msgType': 'chat',
      'msgId': 'aaaaaaaa-1111-2222-3333-444444444444',
      'convId': 'a' * 32,
      'senderUuid': _uuid,
      'senderShortId': CryptoService.shortIdFromUuid(_uuid),
      'senderName': 'Peer',
      'type': 'text',
      'content': 'hello',
      'replyToId': null,
      'replyToPreview': null,
      'timestamp': ts,
      'senderPublicKeyPEM': keys['publicKey'],
    });
    expect(
      crypto.verifyPayloadSignature(
        chatMaterial,
        announceSignature,
        keys['publicKey']!,
      ),
      isFalse,
    );
  });
}
