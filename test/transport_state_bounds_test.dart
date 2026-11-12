import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:ahoy/Ahoy/services/transport/wifi_direct_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ninth review (N-2): the per-transport route, key and scan-state maps are
/// bounded, and UDP announcements are rate-limited per address, so a flood of
/// unique valid announcements cannot grow memory or RSA work without bound.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LAN announcements are rate-limited per address before verification',
      () {
    final lan = LanTransport(announceRatePerWindow: 2);
    expect(lan.debugAllowAnnouncement('192.168.1.50'), isTrue);
    expect(lan.debugAllowAnnouncement('192.168.1.50'), isTrue);
    expect(lan.debugAllowAnnouncement('192.168.1.50'), isFalse,
        reason: 'the third datagram in the window is dropped');
    // A different address has its own window.
    expect(lan.debugAllowAnnouncement('192.168.1.51'), isTrue);
  });

  test('LAN route and key maps stay bounded under unique announcements',
      () async {
    final lan = LanTransport(
      maxRouteEntries: 2,
      maxKnownKeys: 2,
      crypto: CryptoService(),
    );
    final uuids = <String>[];
    for (var i = 0; i < 3; i++) {
      final uuid = _uuidFor(i);
      uuids.add(uuid);
      final crypto = CryptoService();
      final keys = await crypto.generateKeyPair();
      crypto.activate(keys['privateKey']!, keys['publicKey']!);
      final timestamp = DateTime.now().toIso8601String();
      final raw = jsonEncode({
        'type': 'ahoy_announce',
        'uuid': uuid,
        'shortId': CryptoService.shortIdFromUuid(uuid),
        'displayName': 'Peer $i',
        'statusMessage': null,
        'publicKeyPEM': keys['publicKey'],
        'signature': crypto.signAnnouncement(
          uuid: uuid,
          shortId: CryptoService.shortIdFromUuid(uuid),
          displayName: 'Peer $i',
          publicKeyPEM: keys['publicKey'],
          timestamp: timestamp,
        ),
        'timestamp': timestamp,
      });
      lan.debugHandleAnnouncement(raw, InternetAddress.loopbackIPv4);
    }

    expect(lan.debugUuidKeys.length, 2);
    expect(lan.debugPeerConnCount, 2);
    // The oldest entries were evicted; the newest survived.
    expect(lan.debugRouteAddress(uuids[2]), isNotNull);
    expect(lan.debugUuidKeys[uuids[2]], isNotNull);
    expect(lan.debugRouteAddress(uuids[0]), isNull);
  });

  test('WiFi Direct key bindings stay bounded under unique identities',
      () async {
    final wd = WiFiDirectTransport(crypto: CryptoService(), maxKnownKeys: 2);
    for (var i = 0; i < 3; i++) {
      final uuid = _uuidFor(i + 10);
      final crypto = CryptoService();
      final keys = await crypto.generateKeyPair();
      crypto.activate(keys['privateKey']!, keys['publicKey']!);
      final timestamp = DateTime.now().toIso8601String();
      final payload = {
        'type': 'wdIdentity',
        'uuid': uuid,
        'shortId': CryptoService.shortIdFromUuid(uuid),
        'displayName': 'Peer ${i + 10}',
        'statusMessage': null,
        'publicKeyPEM': keys['publicKey'],
        'signature': crypto.signAnnouncement(
          uuid: uuid,
          shortId: CryptoService.shortIdFromUuid(uuid),
          displayName: 'Peer ${i + 10}',
          publicKeyPEM: keys['publicKey'],
          timestamp: timestamp,
        ),
        'timestamp': timestamp,
      };
      wd.debugHandleDataReceived({
        'data': Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        'senderIP': '192.168.43.10',
      });
    }

    expect(wd.debugUuidKeys.length, 2);
    expect(wd.debugUuidKeys[_uuidFor(12)], isNotNull);
    expect(wd.debugUuidKeys[_uuidFor(10)], isNull);
  });
}

String _uuidFor(int seed) {
  final hex = seed.toRadixString(16).padLeft(8, '0');
  return '$hex-1111-4111-8111-111111111111';
}
