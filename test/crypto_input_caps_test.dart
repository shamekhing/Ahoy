
import 'package:ahoy/Ahoy/core/errors.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('oversized untrusted PEM is refused without parsing', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);

    final oversized = '-----BEGIN RSA PUBLIC KEY-----\n'
        '${'A' * (CryptoService.maxPemLength + 1)}\n'
        '-----END RSA PUBLIC KEY-----';

    expect(
      crypto.verifyPayloadSignature('payload', 'sig', oversized),
      isFalse,
    );
    expect(
      () => crypto.encryptForPeer('plain', oversized),
      throwsA(isA<CryptoFormatError>()),
    );
  });

  test('an out-of-range PBKDF2 iteration count fails verification', () async {
    final crypto = CryptoService();
    final tampered =
        'pbkdf2:v2:${CryptoService.maxPasswordHashIterations + 1}:abcd:ef01';

    final sw = Stopwatch()..start();
    final ok = await crypto.verifyPassword('anything', tampered);
    sw.stop();

    expect(ok, isFalse);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'an absurd iteration count must not burn the CPU');
  });

  test('a legitimate stored hash still verifies', () async {
    final crypto = CryptoService();
    final hash = await crypto.hashPassword('correct horse');
    expect(await crypto.verifyPassword('correct horse', hash), isTrue);
    expect(await crypto.verifyPassword('wrong', hash), isFalse);
  });
}
