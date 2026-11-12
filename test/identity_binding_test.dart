import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _realUuid = '11111111-1111-4111-8111-111111111111';
final _correctShortId = CryptoService.shortIdFromUuid(_realUuid);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<DiscoveryProvider> createProvider(CryptoService crypto) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final discovery = DiscoveryService();
    final provider = DiscoveryProvider(
      discovery,
      TransportManager(),
      prefs,
      crypto,
    );
    addTearDown(provider.dispose);
    return provider;
  }

  test('drops announcements whose shortId does not match their UUID', () async {
    final provider = await createProvider(CryptoService());

    provider.onAnnouncement(
      const PeerAnnouncement(
        uuid: _realUuid,
        shortId: 'WRONG1',
        displayName: 'Evil',
        transport: TransportMode.lan,
      ),
    );

    await pumpEventQueue();
    expect(provider.peers, isEmpty);
  });

  test('accepts signed announcements and records the bound public key', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final provider = await createProvider(crypto);

    final announceTs = DateTime.now().toIso8601String();
    final signature = crypto.signAnnouncement(
      uuid: _realUuid,
      shortId: _correctShortId,
      displayName: 'Alice',
      publicKeyPEM: keys['publicKey']!,
      timestamp: announceTs,
    );
    provider.onAnnouncement(
      PeerAnnouncement(
        uuid: _realUuid,
        shortId: _correctShortId,
        displayName: 'Alice',
        publicKeyPEM: keys['publicKey'],
        signature: signature,
        timestamp: announceTs,
        transport: TransportMode.lan,
      ),
    );

    await pumpEventQueue();
    expect(provider.peers, hasLength(1));
    expect(provider.peers.single.displayName, 'Alice');
    expect(provider.peers.single.publicKeyPEM, keys['publicKey']);
  });

  test('drops keyed announcements without a signature', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    final provider = await createProvider(crypto);

    provider.onAnnouncement(
      PeerAnnouncement(
        uuid: _realUuid,
        shortId: _correctShortId,
        displayName: 'Alice',
        publicKeyPEM: keys['publicKey'],
        transport: TransportMode.lan,
      ),
    );

    await pumpEventQueue();
    expect(provider.peers, isEmpty);
  });

  test('drops announcements with an invalid signature', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final provider = await createProvider(crypto);

    final announceTs = DateTime.now().toIso8601String();
    final signature = crypto.signAnnouncement(
      uuid: _realUuid,
      shortId: _correctShortId,
      displayName: 'Alice',
      publicKeyPEM: keys['publicKey']!,
      timestamp: announceTs,
    );
    // Tampered identity field signature no longer matches.
    provider.onAnnouncement(
      PeerAnnouncement(
        uuid: _realUuid,
        shortId: _correctShortId,
        displayName: 'Mallory',
        publicKeyPEM: keys['publicKey'],
        signature: signature,
        transport: TransportMode.lan,
      ),
    );

    await pumpEventQueue();
    expect(provider.peers, isEmpty);
  });

  test('accepts BLE scan-response announcements (MAC uuid, no key)', () async {
    final provider = await createProvider(CryptoService());

    provider.onAnnouncement(
      const PeerAnnouncement(
        uuid: 'AA:BB:CC:DD:EE:FF',
        shortId: 'ABC123',
        displayName: 'Nearby',
        transport: TransportMode.ble,
      ),
    );

    await pumpEventQueue();
    expect(provider.peers, hasLength(1));
    expect(provider.peers.single.uuid, 'AA:BB:CC:DD:EE:FF');
  });

  test('verifyAnnouncement rejects tampered identity fields', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);

    final announceTs = DateTime.now().toIso8601String();
    final signature = crypto.signAnnouncement(
      uuid: _realUuid,
      shortId: _correctShortId,
      displayName: 'Alice',
      publicKeyPEM: keys['publicKey']!,
      timestamp: announceTs,
    );

    expect(
      crypto.verifyAnnouncement(
        uuid: _realUuid,
        shortId: _correctShortId,
        displayName: 'Alice',
        publicKeyPEM: keys['publicKey']!,
        signature: signature,
        timestamp: announceTs,
      ),
      isTrue,
    );
    expect(
      crypto.verifyAnnouncement(
        uuid: _realUuid,
        shortId: _correctShortId,
        displayName: 'Mallory',
        publicKeyPEM: keys['publicKey']!,
        signature: signature,
        timestamp: announceTs,
      ),
      isFalse,
    );
  });

  test('fingerprint is whitespace-insensitive and 12 groups of 5 digits', () {
    final pemA =
        '-----BEGIN RSA PUBLIC KEY-----\nKEY_A\n-----END RSA PUBLIC KEY-----';
    final pemAEvil =
        '-----BEGIN  RSA  PUBLIC  KEY-----\nKEY_A\n-----END RSA PUBLIC KEY-----';
    final pemB =
        '-----BEGIN RSA PUBLIC KEY-----\nKEY_B\n-----END RSA PUBLIC KEY-----';

    final fpA = CryptoService.fingerprintFromPublicKey(pemA);
    expect(fpA, CryptoService.fingerprintFromPublicKey(pemAEvil));
    expect(fpA, isNot(CryptoService.fingerprintFromPublicKey(pemB)));

    final groups = fpA.split(' ');
    expect(groups, hasLength(12));
    for (final group in groups) {
      expect(group.length, 5);
      expect(int.parse(group), lessThan(100000));
    }
  });

  test('safety number is symmetric both devices compute the same digits', () {
    final a = '-----BEGIN RSA PUBLIC KEY-----\nKEY_A\n-----END RSA PUBLIC KEY-----';
    final b = '-----BEGIN RSA PUBLIC KEY-----\nKEY_B\n-----END RSA PUBLIC KEY-----';

    final ab = CryptoService.safetyNumberFor(a, b);
    expect(ab, CryptoService.safetyNumberFor(b, a));

    final groups = ab.split(' ');
    expect(groups, hasLength(12));
    for (final group in groups) {
      expect(group.length, 5);
      expect(int.parse(group), lessThan(100000));
    }
  });

  test('safety number ignores whitespace and distinguishes conversations', () {
    final a = '-----BEGIN RSA PUBLIC KEY-----\nKEY_A\n-----END RSA PUBLIC KEY-----';
    final aEvil = '-----BEGIN  RSA  PUBLIC  KEY-----\nKEY_A\n-----END RSA PUBLIC KEY-----';
    final b = '-----BEGIN RSA PUBLIC KEY-----\nKEY_B\n-----END RSA PUBLIC KEY-----';
    final c = '-----BEGIN RSA PUBLIC KEY-----\nKEY_C\n-----END RSA PUBLIC KEY-----';

    expect(
      CryptoService.safetyNumberFor(a, b),
      CryptoService.safetyNumberFor(aEvil, b),
    );
    expect(
      CryptoService.safetyNumberFor(a, b),
      isNot(CryptoService.safetyNumberFor(a, c)),
    );
    expect(
      CryptoService.safetyNumberFor(a, b),
      isNot(CryptoService.fingerprintFromPublicKey(a)),
    );
  });

  test('shortId collisions with a different key never hijack a peer (audit #6)', () async {
    final discovery = DiscoveryService();
    addTearDown(discovery.dispose);
    const victimUuid = '11111111-1111-4111-8111-111111111111';
    final victimShortId = CryptoService.shortIdFromUuid(victimUuid);

    discovery.onAnnouncement(
      PeerAnnouncement(
        uuid: victimUuid,
        shortId: victimShortId,
        displayName: 'Victim',
        publicKeyPEM: 'KEY_VICTIM',
        transport: TransportMode.lan,
      ),
      const {},
    );

    // An attacker ground a uuid whose shortId collides with the victim's and
    // announces with their own key the merge must be rejected outright.
    const collisionUuid = 'aaaaaaaa-1111-4111-8111-111111111111';
    final alias = discovery.onAnnouncement(
      PeerAnnouncement(
        uuid: collisionUuid,
        shortId: victimShortId,
        displayName: 'Evil',
        publicKeyPEM: 'KEY_EVIL',
        transport: TransportMode.lan,
      ),
      const {},
    );

    expect(alias, isNull);
    final peers = discovery.currentPeers;
    expect(
      peers.any(
        (p) => p.uuid == victimUuid && p.publicKeyPEM == 'KEY_VICTIM',
      ),
      isTrue,
    );
    expect(peers.any((p) => p.uuid == collisionUuid), isFalse);
  });

  test('key changes never overwrite an existing verified key', () async {
    final discovery = DiscoveryService();
    addTearDown(discovery.dispose);
    const uuid = '11111111-1111-4111-8111-111111111111';
    final shortId = CryptoService.shortIdFromUuid(uuid);

    discovery.onAnnouncement(
      PeerAnnouncement(
        uuid: uuid,
        shortId: shortId,
        displayName: 'Peer',
        publicKeyPEM: 'KEY_A',
        transport: TransportMode.lan,
      ),
      const {},
    );
    discovery.onAnnouncement(
      PeerAnnouncement(
        uuid: uuid,
        shortId: shortId,
        displayName: 'Peer',
        publicKeyPEM: 'KEY_B',
        transport: TransportMode.lan,
      ),
      const {},
    );

    expect(discovery.currentPeers.single.publicKeyPEM, 'KEY_A');
  });

  test('a keyless BLE announcement cannot rename a key-verified peer (audit L-5)', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final provider = await createProvider(crypto);
    final announceTs = DateTime.now().toIso8601String();

    provider.onAnnouncement(PeerAnnouncement(
      uuid: _realUuid,
      shortId: _correctShortId,
      displayName: 'Real Name',
      publicKeyPEM: keys['publicKey'],
      signature: crypto.signAnnouncement(
        uuid: _realUuid,
        shortId: _correctShortId,
        displayName: 'Real Name',
        publicKeyPEM: keys['publicKey']!,
        timestamp: announceTs,
      ),
      timestamp: announceTs,
      transport: TransportMode.lan,
    ));
    await pumpEventQueue();
    expect(provider.peers.single.displayName, 'Real Name');

    // A nearby attacker advertising the same shortId over BLE without a key.
    provider.onAnnouncement(PeerAnnouncement(
      uuid: 'AA:BB:CC:DD:EE:FF',
      shortId: _correctShortId,
      displayName: 'Spoofed Name',
      transport: TransportMode.ble,
    ));
    await pumpEventQueue();

    expect(provider.peers.single.displayName, 'Real Name',
        reason: 'keyless announcements never rename verified peers');
  });
}
