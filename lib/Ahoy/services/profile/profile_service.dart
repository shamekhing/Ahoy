import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/constants.dart';
import '../../models/local_user.dart';
import '../crypto/local_data_crypto.dart';
import '../storage/prefs_store.dart';

class ProfileService {
  final PrefsStore _prefsStore;

  /// Required since the round-8 review: a plaintext write path for profile
  /// data and avatars must not exist, even latently (spec §10). Every
  /// construction site already passes the at-rest crypto.
  final LocalDataCrypto _localDataCrypto;
  final Future<Directory> Function() _documentsDirectoryProvider;

  ProfileService(
    this._prefsStore,
    this._localDataCrypto, [
    Future<Directory> Function()? documentsDirectoryProvider,
  ]) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  LocalUser? loadProfile() {
    final raw = _prefsStore.getString(AhoyConstants.prefProfile);
    if (raw == null) return null;

    if (_localDataCrypto.isEncryptedValue(raw)) {
      try {
        final plaintext = _localDataCrypto.decryptString(raw);
        return LocalUser.fromJson(jsonDecode(plaintext) as Map<String, dynamic>);
      } catch (_) {
        // The at-rest key was rotated or lost (reinstall, keystore
        // invalidation). Quarantine the ciphertext so startup and sign-in
        // recover instead of failing forever (audit M-1). The stored private
        // key may still be valid, but without a profile the identity cannot
        // be used, so the user re-registers through the confirmed
        // erase-and-replace flow.
        unawaited(_prefsStore.quarantineValue(AhoyConstants.prefProfile));
        return null;
      }
    }
    // Legacy plaintext row from before at-rest encryption: still readable so
    // the migrator can rewrite it encrypted (audit L-10).
    return LocalUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveProfile(LocalUser user) async {
    await _prefsStore.setString(
      AhoyConstants.prefProfile,
      _localDataCrypto.encryptString(jsonEncode(user.toJson())),
    );
  }

  Future<void> migrateLegacyProfile() async {
    final raw = _prefsStore.getString(AhoyConstants.prefProfile);
    if (raw == null) return;

    final wasPlaintext = !_localDataCrypto.isEncryptedValue(raw);
    var user = loadProfile();
    if (user == null) return;

    final originalAvatarPath = user.avatarPath;
    final avatarPath = await _migrateAvatarPath(user);
    if (avatarPath != originalAvatarPath) {
      user = user.copyWith(avatarPath: avatarPath);
    }

    if (wasPlaintext || avatarPath != originalAvatarPath) {
      await saveProfile(user);
    }
  }

  Future<LocalUser> updateProfile(
    LocalUser current, {
    String? username,
    String? bio,
    List<String>? interests,
    String? statusMessage,
  }) async {
    // Build directly so null bio/statusMessage explicitly clears the field.
    // copyWith(bio: null) would silently keep the old value.
    final updated = LocalUser(
      id: current.id,
      username: username ?? current.username,
      bio: bio,
      avatarPath: current.avatarPath,
      interests: interests ?? current.interests,
      publicKeyPEM: current.publicKeyPEM,
      shortId: current.shortId,
      statusMessage: statusMessage,
      createdAt: current.createdAt,
      biometricEnabled: current.biometricEnabled,
    );
    await saveProfile(updated);
    return updated;
  }

  Future<LocalUser> updateAvatar(LocalUser current) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );
    if (picked == null) return current;

    final appDir = await _documentsDirectoryProvider();
    final destPath =
        '${appDir.path}/avatar_${current.id}.jpg${LocalDataCrypto.encryptedFileExtension}';
    final source = File(picked.path);
    await _localDataCrypto.writeEncryptedFile(
      File(destPath),
      await source.readAsBytes(),
    );

    final updated = current.copyWith(avatarPath: destPath);
    await saveProfile(updated);
    if (current.avatarPath != destPath) {
      await _deleteOwnedAvatar(current.avatarPath, current.id);
    }
    return updated;
  }

  Future<String?> _migrateAvatarPath(LocalUser user) async {
    final avatarPath = user.avatarPath;
    if (avatarPath == null ||
        _localDataCrypto.isEncryptedFilePath(avatarPath)) {
      return avatarPath;
    }

    final source = File(avatarPath);
    if (!await source.exists()) return avatarPath;

    final appDir = await _documentsDirectoryProvider();
    final destPath =
        '${appDir.path}/avatar_${user.id}.jpg${LocalDataCrypto.encryptedFileExtension}';
    await _localDataCrypto.writeEncryptedFile(
      File(destPath),
      await source.readAsBytes(),
    );
    if (destPath != avatarPath) {
      await _deleteOwnedAvatar(avatarPath, user.id);
    }
    return destPath;
  }

  Future<void> _deleteOwnedAvatar(String? path, String userId) async {
    if (path == null) return;
    final file = File(path);
    final name = file.uri.pathSegments.isEmpty
        ? ''
        : file.uri.pathSegments.last;
    if (name != 'avatar_$userId.jpg' &&
        name != 'avatar_$userId.jpg${LocalDataCrypto.encryptedFileExtension}') {
      return;
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
