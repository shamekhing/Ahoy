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

bool _authResult = false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _authResult = false;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<AuthService> createAuth() async {
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
    auth.deviceCredentialVerifier = () async => _authResult;
    return auth;
  }

  test('enabling biometrics without a successful auth leaves the flag off',
      () async {
    final auth = await createAuth();
    await auth.signUp(
      username: 'First',
      password: 'password1',
    );

    _authResult = false;
    expect(await auth.enableBiometric(), isFalse);
    expect(await auth.isBiometricEnabled, isFalse);
  });

  test('a successful auth enables biometrics', () async {
    final auth = await createAuth();
    await auth.signUp(
      username: 'First',
      password: 'password1',
    );

    _authResult = true;
    expect(await auth.enableBiometric(), isTrue);
    expect(await auth.isBiometricEnabled, isTrue);
  });
}
