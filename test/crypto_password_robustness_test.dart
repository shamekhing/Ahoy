import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('valid v2 hashes still verify and wrong passwords still fail', () async {
    final service = CryptoService();
    final hash = await service.hashPassword('correct horse battery staple');

    expect(await service.verifyPassword('correct horse battery staple', hash), isTrue);
    expect(await service.verifyPassword('wrong password', hash), isFalse);
  });

  test('malformed v2 hashes fail closed instead of throwing', () async {
    final service = CryptoService();

    // Odd-length salt.
    expect(
      await service.verifyPassword('x', 'pbkdf2:v2:310000:abc:${'a' * 64}'),
      isFalse,
    );
    // Non-hex salt.
    expect(
      await service.verifyPassword('x', 'pbkdf2:v2:310000:zzzz:${'a' * 64}'),
      isFalse,
    );
    // Derived key of the wrong length.
    expect(
      await service.verifyPassword('x', 'pbkdf2:v2:310000:${'a' * 32}:abcd'),
      isFalse,
    );
    // Non-hex derived key.
    expect(
      await service.verifyPassword('x', 'pbkdf2:v2:310000:${'a' * 32}:${'z' * 64}'),
      isFalse,
    );
  });

  test('malformed legacy PBKDF2 hashes fail closed instead of throwing',
      () async {
    final service = CryptoService();

    expect(
      await service.verifyPassword('x', 'pbkdf2:abc:${'a' * 64}'),
      isFalse,
    );
    expect(
      await service.verifyPassword('x', 'pbkdf2:${'a' * 32}:short'),
      isFalse,
    );
  });

  test('malformed legacy SHA-256 hashes fail closed instead of throwing',
      () async {
    final service = CryptoService();

    expect(
      await service.verifyPassword('x', 'zzzz:${'a' * 64}'),
      isFalse,
    );
    expect(
      await service.verifyPassword('x', '${'a' * 32}:tooshort'),
      isFalse,
    );
    // A hash that is not parseable in any known format.
    expect(await service.verifyPassword('x', 'garbage'), isFalse);
  });
}
