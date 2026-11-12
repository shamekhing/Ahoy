import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';

const _uuid = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startAdvertising signs the identity it advertises (audit #4)', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final tm = TransportManager(crypto: crypto);

    await tm.start(
      uuid: _uuid,
      shortId: CryptoService.shortIdFromUuid(_uuid),
      displayName: 'Alice',
      publicKeyPEM: keys['publicKey'],
      bleEnabled: false,
      lanEnabled: false,
      wifiDirectEnabled: false,
    );
    addTearDown(tm.dispose);

    // Profile edit re-advertises with a new display name.
    await tm.startAdvertising(
      uuid: _uuid,
      shortId: CryptoService.shortIdFromUuid(_uuid),
      displayName: 'Alice Cooper',
      publicKeyPEM: keys['publicKey'],
    );

    final sig = tm.debugAnnouncementSignature;
    final sigTs = tm.debugAnnouncementTimestamp;
    expect(sig, isNotNull);
    expect(sigTs, isNotNull);
    expect(
      crypto.verifyAnnouncement(
        uuid: _uuid,
        shortId: CryptoService.shortIdFromUuid(_uuid),
        displayName: 'Alice Cooper',
        publicKeyPEM: keys['publicKey']!,
        signature: sig!,
        timestamp: sigTs!,
      ),
      isTrue,
    );
    expect(
      crypto.verifyAnnouncement(
        uuid: _uuid,
        shortId: CryptoService.shortIdFromUuid(_uuid),
        displayName: 'Alice',
        publicKeyPEM: keys['publicKey']!,
        signature: sig,
        timestamp: DateTime.now().toIso8601String(),
      ),
      isFalse,
    );
  });

  test('LAN announces without a valid signature poison nothing (audit #5)', () async {
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

    final announceTs = DateTime.now().toIso8601String();
    Map<String, dynamic> announce({String? signature}) => {
      'type': 'ahoy_announce',
      'uuid': _uuid,
      'shortId': CryptoService.shortIdFromUuid(_uuid),
      'displayName': 'Peer',
      'publicKeyPEM': keys['publicKey'],
      'signature': signature,
      'timestamp': announceTs,
    };

    Future<void> sendAnnounce(Map<String, dynamic> json) async {
      final sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      sock.send(utf8.encode(jsonEncode(json)), InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sock.close();
    }

    // Unsigned announce routing state must stay empty.
    await sendAnnounce(announce());
    expect(transport.debugPeerConnCount, 0);

    // A signature over a different displayName must fail.
    final tampered = announce()
      ..['signature'] = crypto.signAnnouncement(
        uuid: _uuid,
        shortId: CryptoService.shortIdFromUuid(_uuid),
        displayName: 'Peer',
        publicKeyPEM: keys['publicKey'],
        timestamp: announceTs,
      )
      ..['displayName'] = 'Mallory';
    await sendAnnounce(tampered);
    expect(transport.debugPeerConnCount, 0);

    // Properly signed announce accepted.
    await sendAnnounce(
      announce(
        signature: crypto.signAnnouncement(
          uuid: _uuid,
          shortId: CryptoService.shortIdFromUuid(_uuid),
          displayName: 'Peer',
          publicKeyPEM: keys['publicKey'],
          timestamp: announceTs,
        ),
      ),
    );
    expect(transport.debugPeerConnCount, 1);
  });
}