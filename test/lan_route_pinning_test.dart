import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _peerUuid = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CryptoService peerCrypto;
  late String peerPublicKeyPEM;

  setUpAll(() async {
    peerCrypto = CryptoService();
    final keys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(keys['privateKey']!, keys['publicKey']!);
    peerPublicKeyPEM = keys['publicKey']!;
  });

  String announcement({String? uuid, String? timestamp}) {
    final id = uuid ?? _peerUuid;
    final ts = timestamp ?? DateTime.now().toIso8601String();
    final shortId = CryptoService.shortIdFromUuid(id);
    return jsonEncode({
      'type': 'ahoy_announce',
      'uuid': id,
      'shortId': shortId,
      'displayName': 'Peer',
      'statusMessage': null,
      'publicKeyPEM': peerPublicKeyPEM,
      'signature': peerCrypto.signAnnouncement(
        uuid: id,
        shortId: shortId,
        displayName: 'Peer',
        statusMessage: null,
        publicKeyPEM: peerPublicKeyPEM,
        timestamp: ts,
      ),
      'timestamp': ts,
    });
  }

  LanTransport transportWithCrypto() => LanTransport(
    discoveryPort: 0,
    messagingPort: 0,
    crypto: peerCrypto,
  );

  test('a verified announcement pins the route to its source address', () {
    final transport = transportWithCrypto();
    addTearDown(transport.dispose);

    transport.debugHandleAnnouncement(announcement(), InternetAddress('127.0.0.1'));

    expect(transport.debugRouteAddress(_peerUuid)?.address, '127.0.0.1');
  });

  test('a captured announcement replayed verbatim is dropped before RSA', () {
    final transport = transportWithCrypto();
    addTearDown(transport.dispose);

    final captured = announcement();
    transport.debugHandleAnnouncement(captured, InternetAddress('127.0.0.1'));
    expect(transport.debugSeenAnnouncementCount, 1);

    // Same bytes, different host: a replay, indistinguishable by signature.
    transport.debugHandleAnnouncement(captured, InternetAddress('127.0.0.2'));
    expect(transport.debugSeenAnnouncementCount, 1);
    expect(transport.debugRouteAddress(_peerUuid)?.address, '127.0.0.1');
  });

  test('a fresh announcement from another address cannot repoint a live route',
      () {
    final transport = transportWithCrypto();
    addTearDown(transport.dispose);

    transport.debugHandleAnnouncement(announcement(), InternetAddress('127.0.0.1'));
    // A different signature (fresh timestamp), same key: the address-change
    // case the replay dedupe cannot cover.
    transport.debugHandleAnnouncement(announcement(), InternetAddress('127.0.0.2'));

    expect(transport.debugRouteAddress(_peerUuid)?.address, '127.0.0.1');
    expect(transport.debugSeenAnnouncementCount, 2);
  });

  test('after the pinned route goes stale another address may take over', () {
    final transport = transportWithCrypto();
    addTearDown(transport.dispose);

    transport.debugHandleAnnouncement(announcement(), InternetAddress('127.0.0.1'));
    transport.debugExpireRoutes();
    transport.debugHandleAnnouncement(announcement(), InternetAddress('127.0.0.2'));

    expect(transport.debugRouteAddress(_peerUuid)?.address, '127.0.0.2');
  });

  test('subnet learning runs through the real announcement pipeline', () {
    final transport = transportWithCrypto();
    addTearDown(transport.dispose);

    // Nothing announced yet: non-loopback hosts are unreachable.
    expect(transport.debugIsAllowedTcpPeer('127.0.0.9'), isTrue);
    expect(transport.debugIsAllowedTcpPeer('10.0.0.5'), isFalse);

    transport.debugHandleAnnouncement(announcement(), InternetAddress('127.0.0.1'));

    expect(transport.debugIsAllowedTcpPeer('10.0.0.5'), isFalse);
  });

  test('a conflicting key is still refused before any state changes', () async {
    final transport = transportWithCrypto();
    addTearDown(transport.dispose);

    transport.debugHandleAnnouncement(announcement(), InternetAddress('127.0.0.1'));
    expect(transport.debugUuidKeys[_peerUuid], peerPublicKeyPEM);

    final impostor = CryptoService();
    final impostorKeys = await impostor.generateKeyPair();
    impostor.activate(impostorKeys['privateKey']!, impostorKeys['publicKey']!);
    final ts = DateTime.now().toIso8601String();
    final shortId = CryptoService.shortIdFromUuid(_peerUuid);
    transport.debugHandleAnnouncement(
      jsonEncode({
        'type': 'ahoy_announce',
        'uuid': _peerUuid,
        'shortId': shortId,
        'displayName': 'Peer',
        'statusMessage': null,
        'publicKeyPEM': impostorKeys['publicKey'],
        'signature': impostor.signAnnouncement(
          uuid: _peerUuid,
          shortId: shortId,
          displayName: 'Peer',
          statusMessage: null,
          publicKeyPEM: impostorKeys['publicKey'],
          timestamp: ts,
        ),
        'timestamp': ts,
      }),
      InternetAddress('127.0.0.3'),
    );

    expect(transport.debugUuidKeys[_peerUuid], peerPublicKeyPEM);
    expect(transport.debugRouteAddress(_peerUuid)?.address, '127.0.0.1');
  });
}
