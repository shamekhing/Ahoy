import 'dart:io';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants.dart';
import '../../core/errors.dart';
import '../../models/local_user.dart';
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

  /// Detects an iOS reinstall: the Keychain survives uninstall while prefs do
  /// not, so a stored password hash without the prefs account marker is a
  /// stale identity whose profile is gone and whose conversations were never
  /// restored. Clear it so the user sees sign-up instead of a "Profile data
  /// missing" dead end (audit M-1).
  Future<void> reconcileReinstall() async {
    final hash = await _secureStore.read(AhoyConstants.keyPasswordHash);
    if (hash == null) return;
    final marker = _prefsStore.getString(AhoyConstants.prefAccountMarker);
    if (marker != null && marker.isNotEmpty) return;
    await _keyStore.clear();
    await _prefsStore.clearAll();
    await _secureStore.clearAll();
    await _localDataCrypto.reset();
  }

  Future<LocalUser> signUp({
    required String username,
    required String password,
    List<String> interests = const [],
    String? bio,
    bool replaceExisting = false,
  }) async {
    if (username.trim().isEmpty) {
      throw const AuthFailed('Username cannot be empty');
    }
    if (password.length < 8) {
      throw const AuthFailed('Password must be at least 8 characters');
    }

    // An account on this device is a real identity with its own keypair.
    // Overwriting it silently would orphan the old conversations and strand
    // peers pinned to the previous key, so an explicit confirmation is
    // required (audit M-2).
    final existingHash = await _secureStore.read(AhoyConstants.keyPasswordHash);
    if (existingHash != null) {
      if (!replaceExisting) {
        throw const AuthFailed('An account already exists on this device');
      }
      // The confirmed replacement starts from a clean slate: the old
      // conversations reference a keypair that no longer exists, their
      // encrypted content is unreadable under the fresh at-rest key, and no
      // file of the old account may survive into the new identity (ninth
      // review N-6 the same sweep signOut performs).
      await _prefsStore.clearAll();
      await _localDataCrypto.reset();
      await _deleteLocalMedia();
    }

    final id = const Uuid().v4();
    final shortId = CryptoService.shortIdFromUuid(id);

    // RSA key generation runs via Isolate.run, so the UI thread is never
    // blocked while the 2048-bit pair is generated.
    final keys = await _cryptoService.generateKeyPair();
    await _keyStore.save(keys['privateKey']!, keys['publicKey']!);
    await _keyStore.load(); // activates CryptoService

    final hash = await _cryptoService.hashPassword(password);
    await _secureStore.write(AhoyConstants.keyUserId, id);
    await _secureStore.write(AhoyConstants.keyPasswordHash, hash);
    // Reinstall detector: the Keychain survives uninstall, prefs do not. A
    // hash without this marker is a stale identity (audit M-1).
    await _prefsStore.setString(AhoyConstants.prefAccountMarker, id);

    final user = LocalUser(
      id: id,
      username: username.trim(),
      bio: bio,
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
    // A legacy (pre-PBKDF2) stored hash is only upgraded by a real password
    // sign-in, so quiet unlock must not bypass the upgrade (round 7,
    // external review A#7): otherwise an account that never types its
    // password again keeps its weak hash forever.
    final storedHash = await _secureStore.read(AhoyConstants.keyPasswordHash);
    if (storedHash != null &&
        _cryptoService.passwordHashNeedsUpgrade(storedHash)) {
      return null;
    }

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

  /// Overridable device-credential check. Defaults to local_auth; injectable
  /// for tests (audit L-14).
  Future<bool> Function()? deviceCredentialVerifier;

  /// Requires a successful device-credential authentication before the
  /// biometric flag is stored: whoever holds the unlocked phone must confirm
  /// they intend to hand over sign-in (audit L-14). Returns whether the
  /// flag was set.
  Future<bool> enableBiometric() async {
    final verify = deviceCredentialVerifier ?? _defaultCredentialVerify;
    if (!await verify()) return false;
    await _secureStore.write(AhoyConstants.keyBiometricEnabled, 'true');
    return true;
  }

  Future<bool> _defaultCredentialVerify() async {
    final canAuth = await _localAuth.canCheckBiometrics ||
        await _localAuth.isDeviceSupported();
    if (!canAuth) return false;
    return _localAuth.authenticate(
      localizedReason: 'Confirm to enable biometric sign in',
      options: const AuthenticationOptions(biometricOnly: false),
    );
  }

  Future<void> disableBiometric() async {
    await _secureStore.delete(AhoyConstants.keyBiometricEnabled);
  }

  // onTransportStop is async we await it before wiping storage so transports
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
    // entry was just deleted and the next launch would brick on decrypt.
    await _localDataCrypto.reset();
    await _deleteLocalMedia();
  }

  /// Removes media files and avatars owned by the signed-out account.
  /// Covers both the documents directory (encrypted media, avatars) and the
  /// temp directory (voice recorder temps, image_picker cache copies that a
  /// crashed send may have left behind) so no plaintext survives sign-out
  /// (audit M-5).
  Future<void> _deleteLocalMedia() async {
    final dirs = <Directory>[];
    try {
      dirs.add(await getApplicationDocumentsDirectory());
    } catch (_) {}
    try {
      dirs.add(await getTemporaryDirectory());
    } catch (_) {}
    for (final dir in dirs) {
      try {
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.isEmpty
              ? ''
              : entity.uri.pathSegments.last;
          final owned = name.startsWith('ahoy_media_') ||
              name.startsWith('ahoy_voice_') ||
              name.startsWith('ahoy_audio_') ||
              name.startsWith('avatar_') ||
              name.startsWith('image_picker') ||
              name.startsWith('camera_picker');
          if (!owned) continue;
          try {
            await entity.delete();
          } catch (_) {}
        }
      } catch (_) {}
    }
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
