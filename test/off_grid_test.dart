import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uuid = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<TransportManager> startedManager(
    CryptoService crypto, {
    required bool offGrid,
  }) async {
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final tm = TransportManager(crypto: crypto);
    await tm.start(
      uuid: _uuid,
      shortId: CryptoService.shortIdFromUuid(_uuid),
      displayName: 'Alice',
      publicKeyPEM: keys['publicKey'],
      // Transports stay disabled so the test binds no sockets and cannot
      // collide with the transport test files. The Off the Grid gates live in
      // TransportManager before any transport call, which is what these
      // assertions exercise.
      bleEnabled: false,
      lanEnabled: false,
      wifiDirectEnabled: false,
      offGrid: offGrid,
    );
    return tm;
  }

  test('cold start with Off the Grid performs zero advertise passes', () async {
    final tm = await startedManager(CryptoService(), offGrid: true);
    addTearDown(tm.dispose);

    expect(tm.offGrid, isTrue);
    expect(tm.debugAdvertiseCount, 0);
  });

  test('refresh, transport toggles and profile edits stay silent off grid',
      () async {
    final tm = await startedManager(CryptoService(), offGrid: true);
    addTearDown(tm.dispose);

    // Pull-to-refresh re-enables transports (audit H-3); BLE is toggled here
    // because LAN binds real ports that other test files may hold.
    await tm.setBleEnabled(false);
    await tm.setBleEnabled(true);
    // Profile edit re-advertise (audit H-3).
    await tm.refreshAdvertising();
    // Legacy resume path must also stay suppressed.
    await tm.resumeAdvertising();

    expect(tm.debugAdvertiseCount, 0);
  });

  test('leaving Off the Grid resumes advertising', () async {
    final tm = await startedManager(CryptoService(), offGrid: true);
    addTearDown(tm.dispose);
    expect(tm.debugAdvertiseCount, 0);

    await tm.setOffGrid(false);
    await tm.refreshAdvertising();
    expect(tm.debugAdvertiseCount, 1);
  });

  test('a normal start still advertises exactly once', () async {
    final tm = await startedManager(CryptoService(), offGrid: false);
    addTearDown(tm.dispose);
    expect(tm.offGrid, isFalse);
    expect(tm.debugAdvertiseCount, 1);
  });

  test('Off the Grid persists across a restart and refreshPeers stays silent',
      () async {
    // Cold start: the flag comes from the persisted preference, exactly like
    // RootScreen seeds TransportManager from DiscoveryProvider (audit H-3).
    SharedPreferences.setMockInitialValues({
      AhoyConstants.prefOffGrid: true,
      AhoyConstants.prefBleEnabled: false,
      AhoyConstants.prefLanEnabled: false,
      AhoyConstants.prefWifiDirectEnabled: false,
    });
    final prefs = PrefsStore();
    await prefs.init();
    final discovery = DiscoveryProvider(
      DiscoveryService(),
      TransportManager(),
      prefs,
      CryptoService(),
    );
    addTearDown(discovery.dispose);
    expect(discovery.offGrid, isTrue);

    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final tm = TransportManager(crypto: crypto);
    addTearDown(tm.dispose);
    await tm.start(
      uuid: _uuid,
      shortId: CryptoService.shortIdFromUuid(_uuid),
      displayName: 'Alice',
      publicKeyPEM: keys['publicKey'],
      bleEnabled: discovery.bleEnabled,
      lanEnabled: discovery.lanEnabled,
      wifiDirectEnabled: discovery.wifiDirectEnabled,
      offGrid: discovery.offGrid,
    );
    expect(tm.debugAdvertiseCount, 0);

    // Pull-to-refresh round-trips every enabled transport; with the flag set
    // nothing may be broadcast (audit H-3).
    await discovery.refreshPeers();
    await tm.refreshAdvertising();
    expect(tm.debugAdvertiseCount, 0);
  });
}
