import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/constants.dart';
import 'prefs_store.dart';

class SecureStore {
  final FlutterSecureStorage _storage;

  SecureStore()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        // first_unlock_this_device keeps the at-rest data key off iCloud
        // backups and device transfer, matching the Android backup policy
        // (audit M-1). Encrypted prefs and the key that unlocks them must
        // never travel together.
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  Future<String?> read(String key) async {
    return _storage.read(key: key);
  }

  Future<bool> has(String key) async {
    final value = await _storage.read(key: key);
    return value != null;
  }

  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }

  Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  /// One-time rewrite of existing items so the device-bound iOS
  /// accessibility option applies to keys written by older builds
  /// (audit M-1). flutter_secure_storage only applies options at write time,
  /// so existing values must be read, deleted and rewritten. No-op on other
  /// platforms; the marker lives in prefs so it survives with the data.
  Future<void> migrateAccessibility(PrefsStore prefs) async {
    if (!Platform.isIOS) return;
    const marker = 'ahoy_keychain_accessibility_migrated';
    if (prefs.getBool(marker)) return;
    const keys = [
      AhoyConstants.keyUserId,
      AhoyConstants.keyPasswordHash,
      AhoyConstants.keyPrivateKey,
      AhoyConstants.keyPublicKey,
      AhoyConstants.keyBiometricEnabled,
      AhoyConstants.keyLocalDataKey,
    ];
    for (final key in keys) {
      final value = await read(key);
      if (value == null) continue;
      await delete(key);
      await write(key, value);
    }
    await prefs.setBool(marker, value: true);
  }
}
