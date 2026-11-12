import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the discovery-list duplicate flood: BLE scan
/// responses are keyed by the peer's current advertising MAC, which Android
/// rotates, so every scan restart (pull-to-refresh) used to file the same
/// device under a fresh key. The service must keep one record per shortId.
const _realUuid = '22222222-2222-4222-8222-222222222222';
final _shortId = CryptoService.shortIdFromUuid(_realUuid);
const _blocked = <String>{};

PeerAnnouncement _ble(String mac) => PeerAnnouncement(
  uuid: mac,
  shortId: _shortId,
  displayName: 'Peer',
  transport: TransportMode.ble,
);

void main() {
  test('rotating BLE MACs do not duplicate a peer across scan restarts', () {
    final service = DiscoveryService();

    // Three pull-to-refresh cycles, each seeing a rotated MAC.
    service.onAnnouncement(_ble('AA:BB:CC:00:00:01'), _blocked);
    service.onAnnouncement(_ble('AA:BB:CC:00:00:02'), _blocked);
    service.onAnnouncement(_ble('AA:BB:CC:00:00:03'), _blocked);

    expect(service.currentPeers, hasLength(1));
    expect(service.currentPeers.single.shortId, _shortId);
    expect(service.currentPeers.single.displayName, 'Peer');
  });

  test('one signed announcement absorbs every stale MAC entry', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final service = DiscoveryService();

    service.onAnnouncement(_ble('AA:BB:CC:00:00:01'), _blocked);
    service.onAnnouncement(_ble('AA:BB:CC:00:00:02'), _blocked);
    service.onAnnouncement(_ble('AA:BB:CC:00:00:03'), _blocked);

    final ts = DateTime.now().toIso8601String();
    final signature = crypto.signAnnouncement(
      uuid: _realUuid,
      shortId: _shortId,
      displayName: 'Peer',
      publicKeyPEM: keys['publicKey']!,
      timestamp: ts,
    );
    service.onAnnouncement(
      PeerAnnouncement(
        uuid: _realUuid,
        shortId: _shortId,
        displayName: 'Peer',
        publicKeyPEM: keys['publicKey'],
        signature: signature,
        timestamp: ts,
        transport: TransportMode.wifiDirect,
      ),
      _blocked,
    );

    expect(service.currentPeers, hasLength(1));
    expect(service.currentPeers.single.uuid, _realUuid);
    // The verified key survives the absorption.
    expect(service.currentPeers.single.publicKeyPEM, keys['publicKey']);
  });

  test('a fresh rotated MAC after canonical binding aliases, not duplicates',
      () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final service = DiscoveryService();

    final ts = DateTime.now().toIso8601String();
    final signature = crypto.signAnnouncement(
      uuid: _realUuid,
      shortId: _shortId,
      displayName: 'Peer',
      publicKeyPEM: keys['publicKey']!,
      timestamp: ts,
    );
    service.onAnnouncement(
      PeerAnnouncement(
        uuid: _realUuid,
        shortId: _shortId,
        displayName: 'Peer',
        publicKeyPEM: keys['publicKey'],
        signature: signature,
        timestamp: ts,
        transport: TransportMode.wifiDirect,
      ),
      _blocked,
    );

    // The MAC rotates after the identity is known: the record must stay a
    // single verified entry (and the keyless scan response must not rename
    // or unverify it, audit L-5).
    service.onAnnouncement(_ble('AA:BB:CC:00:00:09'), _blocked);

    expect(service.currentPeers, hasLength(1));
    expect(service.currentPeers.single.uuid, _realUuid);
    expect(service.currentPeers.single.publicKeyPEM, keys['publicKey']);
  });
}
