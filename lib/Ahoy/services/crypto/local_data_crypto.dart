import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

import '../../core/constants.dart';
import 'local_file_policy.dart';
import '../storage/secure_store.dart';

class LocalDataCrypto {
  static const String encryptedValuePrefix = 'ahoyenc:v1:';
  static const String encryptedFileExtension = '.ahoyenc';

  final SecureStore _secureStore;
  enc.Key? _key;

  LocalDataCrypto(this._secureStore);

  LocalDataCrypto.withKeyForTesting(Uint8List keyBytes)
    : _secureStore = SecureStore(),
      _key = enc.Key(keyBytes);

  Future<void> init() async {
    final stored = await _secureStore.read(AhoyConstants.keyLocalDataKey);
    if (stored != null) {
      _key = enc.Key(base64.decode(stored));
      return;
    }

    final keyBytes = _randomBytes(32);
    await _secureStore.write(
      AhoyConstants.keyLocalDataKey,
      base64.encode(keyBytes),
    );
    _key = enc.Key(keyBytes);
  }

  /// Generates a fresh at-rest key, persists it, and swaps it into memory.
  /// Called on sign-out so a follow-up sign-up cannot encrypt data with the
  /// in-memory key whose SecureStore entry was just deleted — that mismatch
  /// would brick decryption on the next launch.
  Future<void> reset() async {
    final keyBytes = _randomBytes(32);
    await _secureStore.write(
      AhoyConstants.keyLocalDataKey,
      base64.encode(keyBytes),
    );
    _key = enc.Key(keyBytes);
  }

  bool isEncryptedValue(String value) => value.startsWith(encryptedValuePrefix);

  bool isEncryptedFilePath(String path) =>
      path.endsWith(encryptedFileExtension);

  String encryptString(String plaintext) {
    final key = _requireKey();
    final iv = enc.IV(_randomBytes(12));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final envelope = jsonEncode({
      'iv': base64.encode(iv.bytes),
      'ct': encrypted.base64,
    });
    return '$encryptedValuePrefix${base64.encode(utf8.encode(envelope))}';
  }

  String decryptString(String encryptedValue) {
    final key = _requireKey();
    if (!isEncryptedValue(encryptedValue)) {
      throw const FormatException('Value is not an Ahoy encrypted payload');
    }
    final envelope =
        jsonDecode(
              utf8.decode(
                base64.decode(
                  encryptedValue.substring(encryptedValuePrefix.length),
                ),
              ),
            )
            as Map<String, dynamic>;
    final iv = enc.IV(base64.decode(envelope['iv'] as String));
    final ciphertext = enc.Encrypted.fromBase64(envelope['ct'] as String);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    return encrypter.decrypt(ciphertext, iv: iv);
  }

  Future<void> writeEncryptedFile(File file, Uint8List bytes) async {
    await file.writeAsString(encryptString(base64.encode(bytes)), flush: true);
    await LocalFilePolicy.excludeFromBackup(file);
  }

  Uint8List readEncryptedFileSync(File file) {
    return base64.decode(decryptString(file.readAsStringSync()));
  }

  Future<Uint8List> readEncryptedFile(File file) async {
    return base64.decode(decryptString(await file.readAsString()));
  }

  enc.Key _requireKey() {
    final key = _key;
    if (key == null) {
      throw StateError('LocalDataCrypto has not been initialized');
    }
    return key;
  }

  Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }
}
