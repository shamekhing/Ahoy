import 'dart:convert';

import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new password hashes use versioned PBKDF2 parameters', () async {
    final service = CryptoService();

    final hash = await service.hashPassword('correct horse battery staple');

    expect(
      hash,
      startsWith('pbkdf2:v2:${CryptoService.passwordHashIterations}:'),
    );
    expect(
      await service.verifyPassword('correct horse battery staple', hash),
      isTrue,
    );
    expect(service.passwordHashNeedsUpgrade(hash), isFalse);
  });

  test('legacy SHA password hashes still verify and require upgrade', () async {
    final service = CryptoService();
    const saltHex = '00112233445566778899aabbccddeeff';
    final digest = crypto.sha256
        .convert(utf8.encode('${saltHex}correct horse battery staple'))
        .toString();
    final legacyHash = '$saltHex:$digest';

    expect(
      await service.verifyPassword('correct horse battery staple', legacyHash),
      isTrue,
    );
    expect(service.passwordHashNeedsUpgrade(legacyHash), isTrue);
  });
}
