import 'dart:io';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../models/local_user.dart';
import '../../core/enums.dart';
import '../crypto/crypto_service.dart';
import '../crypto/key_store.dart';
import '../crypto/local_data_crypto.dart';
import '../profile/profile_service.dart';
import '../storage/prefs_store.dart';
import '../storage/secure_store.dart';

class AuthService {
  final SecureStore _secureStore;
  final PrefsStore _prefsStore;
  final ProfileService _profileService;
  final CryptoService _cryptoService;
  final KeyStore _keyStore;
  final LocalDataCrypto _localDataCrypto;
  final LocalAuthentication _localAuth = LocalAuthentication();

  AuthService(
    this._secureStore,
    this._prefsStore,
    this._profileService,
    this._cryptoService,
    this._keyStore,
    this._localDataCrypto,
  );

  Future<bool> get isSignedIn =>
      _secureStore.has(AhoyConstants.keyPasswordHash);

  Future<LocalUser> signUp({
    required String username,
    required String password,
    required Gender gender,
    List<String> interests = const [],
    String? bio,
  }) async {
    if (username.trim().isEmpty) {
      throw const AuthFailed('Username cannot be empty');
    }
    if (password.length < 8) {
      throw const AuthFailed('Password must be at least 8 characters');
    }

    final id = const Uuid().v4();
    final shortId = CryptoService.shortIdFromUuid(id);

    // RSA key generation runs in a separate isolate — never blocks the UI thread.
    final keys = await _cryptoService.generateKeyPair();
    await _keyStore.save(keys['privateKey']!, keys['publicKey']!);
    await _keyStore.load(); // activates CryptoService

    final hash = await _cryptoService.hashPassword(password);
    await _secureStore.write(AhoyConstants.keyUserId, id);
    await _secureStore.write(AhoyConstants.keyPasswordHash, hash);

    final user = LocalUser(
      id: id,
      username: username.trim(),
      bio: bio,
      gender: gender,
      interests: interests,
      publicKeyPEM: keys['publicKey']!,
      shortId: shortId,
      createdAt: DateTime.now(),
    );

    await _profileService.saveProfile(user);
    return user;
  }

  Future<LocalUser> signIn({required String password}) async {
    final storedHash = await _secureStore.read(AhoyConstants.keyPasswordHash);
    if (storedHash == null) {
      throw const AuthFailed('No account found on this device');
    }

    if (!await _cryptoService.verifyPassword(password, storedHash)) {
      throw const AuthFailed('Incorrect password');
    }

    if (_cryptoService.passwordHashNeedsUpgrade(storedHash)) {
      await _secureStore.write(
        AhoyConstants.keyPasswordHash,
        await _cryptoService.hashPassword(password),
      );
    }

    await _keyStore.load();

    final profile = _profileService.loadProfile();
    if (profile == null) throw const AuthFailed('Profile data missing');
    return profile;
  }

  Future<LocalUser?> signInWithBiometric() async {
    final biometricEnabled = await _secureStore.read(
      AhoyConstants.keyBiometricEnabled,
    );
    if (biometricEnabled != 'true') return null;

    final canAuth =
        await _localAuth.canCheckBiometrics ||
        await _localAuth.isDeviceSupported();
    if (!canAuth) return null;

    final authenticated = await _localAuth.authenticate(
      localizedReason: 'Sign in to Ahoy',
      options: const AuthenticationOptions(biometricOnly: false),
    );
    if (!authenticated) return null;

    await _keyStore.load();
    return _profileService.loadProfile();
  }

  Future<void> enableBiometric() async {
    await _secureStore.write(AhoyConstants.keyBiometricEnabled, 'true');
  }

  Future<void> disableBiometric() async {
    await _secureStore.delete(AhoyConstants.keyBiometricEnabled);
  }

  // onTransportStop is async — we await it before wiping storage so transports
  // are fully stopped before their data disappears underneath them.
  Future<void> signOut({
    required Future<void> Function() onTransportStop,
  }) async {
    await onTransportStop();
    await _keyStore.clear();
    await _prefsStore.clearAll();
    await _secureStore.clearAll();
    // Install a fresh at-rest key for the next account and remove the
    // previous account's media. Without the reset, a same-process
    // re-registration would encrypt with the in-memory key whose SecureStore
    // entry was just deleted — and the next launch would brick on decrypt.
    await _localDataCrypto.reset();
    await _deleteLocalMedia();
  }

  /// Removes media files and avatars owned by the signed-out account.
  Future<void> _deleteLocalMedia() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('ahoy_media_') || name.startsWith('avatar_')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<bool> get isBiometricEnabled async {
    final value = await _secureStore.read(AhoyConstants.keyBiometricEnabled);
    return value == 'true';
  }

  Future<bool> get isBiometricAvailable async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return await _localAuth.canCheckBiometrics ||
        await _localAuth.isDeviceSupported();
  }
}
