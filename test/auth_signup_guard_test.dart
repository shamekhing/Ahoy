import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/core/errors.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AuthService> createAuth() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final secure = SecureStore();
    final prefs = PrefsStore();
    await prefs.init();
    final crypto = CryptoService();
    final keyStore = KeyStore(secure, crypto);
    final localDataCrypto = LocalDataCrypto(secure);
    await localDataCrypto.init();
    final profileService = ProfileService(prefs, localDataCrypto);
    return AuthService(
      secure,
      prefs,
      profileService,
      crypto,
      keyStore,
      localDataCrypto,
    );
  }

  test('sign up with no existing account succeeds', () async {
    final auth = await createAuth();

    final user = await auth.signUp(
      username: 'First',
      password: 'password1',
      gender: Gender.unspecified,
    );

    expect(user.username, 'First');
    expect(user.publicKeyPEM, isNotEmpty);
  });

  test('a second sign up is refused unless explicitly confirmed', () async {
    final auth = await createAuth();
    await auth.signUp(
      username: 'First',
      password: 'password1',
      gender: Gender.unspecified,
    );

    // The naive path taken by the sign-in screen link must not replace the
    // existing identity (audit M-2).
    await expectLater(
      auth.signUp(
        username: 'Second',
        password: 'password1',
        gender: Gender.unspecified,
      ),
      throwsA(isA<AuthFailed>()),
    );

    // The refused attempt must not have touched key material or profile: the
    // original password still signs in.
    expect(await auth.signIn(password: 'password1'), isNotNull);
  });

  test('explicit confirmation replaces the identity', () async {
    final auth = await createAuth();
    final first = await auth.signUp(
      username: 'First',
      password: 'password1',
      gender: Gender.unspecified,
    );

    final second = await auth.signUp(
      username: 'Second',
      password: 'password2',
      gender: Gender.unspecified,
      replaceExisting: true,
    );

    expect(second.id, isNot(first.id));
    expect(second.publicKeyPEM, isNot(first.publicKeyPEM));
    expect(await auth.signIn(password: 'password2'), isNotNull);
    await expectLater(
      auth.signIn(password: 'password1'),
      throwsA(isA<AuthFailed>()),
    );
  });
}

