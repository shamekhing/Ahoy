import 'package:ahoy/Ahoy/services/crypto/peer_trust_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _victimUuid = '11111111-1111-4111-8111-111111111111';
const _victimKey = '-----BEGIN RSA PUBLIC KEY-----\nVICTIM\n-----END RSA PUBLIC KEY-----';

String _uuid(int i) => '33333333-0000-4000-8000-${i.toString().padLeft(12, '0')}';

String _key(int i) => '-----BEGIN RSA PUBLIC KEY-----\nKEY_$i\n-----END RSA PUBLIC KEY-----';

void main() {
  test('a safety-number-verified record survives an announcement flood',
      () {
    final store = PeerTrustStore();
    store.observe(_victimUuid, _victimKey);
    store.markSafetyNumberVerified(_victimUuid);

    for (var i = 0; i < 256; i++) {
      store.observe(_uuid(i), _key(i));
    }

    final victim = store.get(_victimUuid);
    expect(victim, isNotNull);
    expect(victim!.state, PeerTrustState.verifiedBySafetyNumber);
    expect(victim.key, _victimKey);
  });

  test('a pinned record outranks unverified records under pressure', () {
    final store = PeerTrustStore();
    store.observe(_victimUuid, _victimKey);
    store.markPinned(_victimUuid);

    for (var i = 0; i < 256; i++) {
      store.observe(_uuid(i), _key(i));
    }

    final victim = store.get(_victimUuid);
    expect(victim, isNotNull);
    expect(victim!.state, PeerTrustState.pinned);
  });

  test('with only verified records left, a new entry is the one evicted', () {
    final store = PeerTrustStore();
    for (var i = 0; i < PeerTrustStore.maxEntries; i++) {
      final uuid = _uuid(i);
      store.observe(uuid, _key(i));
      store.markSafetyNumberVerified(uuid);
    }

    final newcomer = _uuid(9999);
    store.observe(newcomer, _key(9999));

    // The cap is respected and every verified record survives.
    expect(store.length, PeerTrustStore.maxEntries);
    expect(store.get(newcomer), isNull);
    expect(
      store.get(_uuid(0))!.state,
      PeerTrustState.verifiedBySafetyNumber,
    );
    expect(
      store.get(_uuid(PeerTrustStore.maxEntries - 1))!.state,
      PeerTrustState.verifiedBySafetyNumber,
    );
  });
}
