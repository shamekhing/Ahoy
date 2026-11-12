import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter_test/flutter_test.dart';

const _realUuidA = '11111111-1111-4111-8111-111111111111';
const _realUuidB = '22222222-2222-4222-8222-222222222222';

String _mac(int i) =>
    'AA:BB:CC:DD:EE:${i.toRadixString(16).padLeft(2, '0').toUpperCase()}';

String _realUuid(int i) =>
    '44444444-0000-4000-8000-${i.toString().padLeft(12, '0')}';

/// Spec §8: temporary transport identifiers (MAC addresses) are capped in
/// their own routing table so ambient BLE devices cannot churn real peers
/// out of the verified-UUID table (round 8).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('temp-id entries are capped separately from real peers', () {
    final tm = TransportManager();
    addTearDown(tm.dispose);

    for (var i = 0; i < 200; i++) {
      tm.debugRecordTransport(_mac(i), TransportMode.ble);
    }
    expect(tm.debugTempTransportEntries, AhoyConstants.maxTempPeerEntries);
    expect(tm.debugRealTransportEntries, 0);

    // Real peers are untouched by the ambient churn.
    tm.debugRecordTransport(_realUuidA, TransportMode.lan);
    tm.debugRecordTransport(_realUuidB, TransportMode.ble);
    expect(tm.debugRealTransportEntries, 2);
    expect(tm.currentModeFor(_realUuidA), TransportMode.lan);

    // The verified-UUID table caps on its own; eviction stays FIFO, so the
    // earliest entries go first while the newest survive.
    for (var i = 0; i < 600; i++) {
      tm.debugRecordTransport(_realUuid(i), TransportMode.lan);
    }
    expect(tm.debugRealTransportEntries, 512);
    expect(tm.currentModeFor(_realUuidA), TransportMode.none);
    expect(tm.currentModeFor(_realUuid(599)), TransportMode.lan);
  });

  test('registerAlias merges the temp entry into the real table', () {
    final tm = TransportManager();
    addTearDown(tm.dispose);

    tm.debugRecordTransport(_mac(7), TransportMode.ble);
    tm.debugRecordTransport(_realUuidA, TransportMode.lan);

    tm.registerAlias(tempId: _mac(7), canonicalId: _realUuidA);

    expect(tm.debugTempTransportEntries, 0);
    // The merged mode set {lan, ble} resolves by transport priority.
    expect(tm.currentModeFor(_realUuidA), TransportMode.lan);
  });
}
