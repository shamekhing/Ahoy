import 'dart:convert';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('a legacy stored hash blocks quiet unlock until a password upgrade',
      () async {
    final harness = await _createHarness();
    await harness.auth.signUp(
      username: 'First',
      password: 'password1',
      gender: Gender.unspecified,
    );
    // Simulate an account created before the PBKDF2 migration and a user
    // who enabled biometrics back then.
    const saltHex = '00112233445566778899aabbccddeeff';
    final digest = crypto.sha256
        .convert(utf8.encode('${saltHex}password1'))
        .toString();
    await harness.secure.write(
      AhoyConstants.keyPasswordHash,
      '$saltHex:$digest',
    );
    await harness.secure.write(AhoyConstants.keyBiometricEnabled, 'true');

    // Quiet unlock is refused: it would bypass the hash upgrade forever.
    expect(await harness.auth.signInWithBiometric(), isNull);

    // The password path still works and upgrades the stored hash.
    final user = await harness.auth.signIn(password: 'password1');
    expect(user.username, 'First');
    final upgraded = await harness.secure.read(
      AhoyConstants.keyPasswordHash,
    );
    expect(upgraded, startsWith('pbkdf2:v2:'));

    // Round-trip integrity of the upgraded hash.
    expect(
      await harness.crypto.verifyPassword('password1', upgraded!),
      isTrue,
    );
  });

  test('legacy detection covers both legacy PBKDF2 and SHA-256 formats', () {
    final cryptoService = CryptoService();
    expect(
      cryptoService.passwordHashNeedsUpgrade('0011:digest'),
      isTrue,
    );
    expect(
      cryptoService.passwordHashNeedsUpgrade('pbkdf2:0011:digest'),
      isTrue,
    );
    expect(
      cryptoService.passwordHashNeedsUpgrade(
        'pbkdf2:v2:${CryptoService.passwordHashIterations}:0011:digest',
      ),
      isFalse,
    );
  });
}

class _Harness {
  final AuthService auth;
  final SecureStore secure;
  final CryptoService crypto;

  const _Harness({
    required this.auth,
    required this.secure,
    required this.crypto,
  });
}

Future<_Harness> _createHarness() async {
  final secure = SecureStore();
  final prefs = PrefsStore();
  await prefs.init();
  final crypto = CryptoService();
  final keyStore = KeyStore(secure, crypto);
  final localDataCrypto = LocalDataCrypto(secure);
  await localDataCrypto.init();
  final auth = AuthService(
    secure,
    prefs,
    ProfileService(prefs, localDataCrypto),
    crypto,
    keyStore,
    localDataCrypto,
  );
  return _Harness(auth: auth, secure: secure, crypto: crypto);
}
