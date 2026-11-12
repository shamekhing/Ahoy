import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _corruptEnvelope = 'ahoyenc:v1:bm90IGpzb24='; // base64 of "not json"

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('undecryptable conversations are quarantined and read as empty',
      () async {
    SharedPreferences.setMockInitialValues({
      'ahoy_conversations': _corruptEnvelope,
    });
    final prefs = PrefsStore();
    await prefs.init();
    final store = ConversationStore(
      prefs,
      LocalDataCrypto.withKeyForTesting(
        Uint8List.fromList(List.generate(32, (i) => i + 1)),
      ),
    );

    expect(store.loadAll(), isEmpty);
    await pumpEventQueue();
    expect(prefs.getString('ahoy_conversations'), isNull);
    expect(prefs.getString('ahoy_corrupt_ahoy_conversations'),
        _corruptEnvelope);
  });

  test('undecryptable message history is quarantined and read as empty',
      () async {
    SharedPreferences.setMockInitialValues({
      'ahoy_msgs_conv-1': _corruptEnvelope,
    });
    final prefs = PrefsStore();
    await prefs.init();
    final store = MessageStore(
      prefs,
      LocalDataCrypto.withKeyForTesting(
        Uint8List.fromList(List.generate(32, (i) => i + 1)),
      ),
    );

    expect(store.loadMessages('conv-1'), isEmpty);
    await pumpEventQueue();
    expect(prefs.getString('ahoy_msgs_conv-1'), isNull);
    expect(prefs.getString('ahoy_corrupt_ahoy_msgs_conv-1'), _corruptEnvelope);
  });

  test('an undecryptable profile is quarantined and loadProfile returns null',
      () async {
    SharedPreferences.setMockInitialValues({
      'ahoy_profile': _corruptEnvelope,
    });
    final prefs = PrefsStore();
    await prefs.init();
    final service = ProfileService(
      prefs,
      LocalDataCrypto.withKeyForTesting(
        Uint8List.fromList(List.generate(32, (i) => i + 1)),
      ),
    );

    expect(service.loadProfile(), isNull);
    await pumpEventQueue();
    expect(prefs.getString('ahoy_profile'), isNull);
    expect(prefs.getString('ahoy_corrupt_ahoy_profile'), _corruptEnvelope);
  });

  test('undecryptable media files are renamed aside and read as empty',
      () async {
    final dir = await Directory.systemTemp.createTemp('ahoy_recovery_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/ahoy_media_x.jpg.ahoyenc');
    await file.writeAsString(_corruptEnvelope, flush: true);

    final crypto = LocalDataCrypto.withKeyForTesting(
      Uint8List.fromList(List.generate(32, (i) => i + 1)),
    );

    expect(await crypto.readEncryptedFile(file), isEmpty);
    expect(file.existsSync(), isFalse);
    expect(File('${file.path}.ahoycorrupt').existsSync(), isTrue);

    // The sync reader recovers the same way.
    final file2 = File('${dir.path}/ahoy_media_y.jpg.ahoyenc');
    await file2.writeAsString(_corruptEnvelope, flush: true);
    expect(crypto.readEncryptedFileSync(file2), isEmpty);
    expect(file2.existsSync(), isFalse);
    expect(File('${file2.path}.ahoycorrupt').existsSync(), isTrue);
  });

  test('quarantining sets the one-time notice flag', () async {
    SharedPreferences.setMockInitialValues({
      'ahoy_conversations': _corruptEnvelope,
    });
    final prefs = PrefsStore();
    await prefs.init();
    final store = ConversationStore(
      prefs,
      LocalDataCrypto.withKeyForTesting(
        Uint8List.fromList(List.generate(32, (i) => i + 1)),
      ),
    );

    expect(store.loadAll(), isEmpty);
    await pumpEventQueue();
    expect(prefs.getBool(AhoyConstants.prefQuarantineNotice), isTrue);
  });

  test('a reinstall is detected when the Keychain outlives prefs', () async {
    // Simulates an iOS reinstall: secure storage keeps the identity, prefs
    // (with the account marker) are gone (audit M-1).
    FlutterSecureStorage.setMockInitialValues({
      'ahoy_user_id': 'old-id',
      'ahoy_password_hash': 'old-hash',
      'ahoy_private_key': 'old-key',
    });
    SharedPreferences.setMockInitialValues({});
    final secure = SecureStore();
    final prefs = PrefsStore();
    await prefs.init();
    final crypto = CryptoService();
    final keyStore = KeyStore(secure, crypto);
    final localDataCrypto = LocalDataCrypto(secure);
    await localDataCrypto.init();
    final authService = AuthService(
      secure,
      prefs,
      ProfileService(prefs, localDataCrypto),
      crypto,
      keyStore,
      localDataCrypto,
    );
    expect(await authService.isSignedIn, isTrue);

    await authService.reconcileReinstall();

    expect(authService.isSignedIn, completion(isFalse));
    expect(await secure.read('ahoy_user_id'), isNull);
    expect(await crypto.isReady, isFalse,
        reason: 'the stale keypair must not stay activated');
  });

  test('an account marker prevents reinstall detection from wiping data',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'ahoy_user_id': 'current-id',
      'ahoy_password_hash': 'current-hash',
    });
    SharedPreferences.setMockInitialValues({
      'ahoy_account_marker': 'current-id',
    });
    final secure = SecureStore();
    final prefs = PrefsStore();
    await prefs.init();
    final crypto = CryptoService();
    final keyStore = KeyStore(secure, crypto);
    final localDataCrypto = LocalDataCrypto(secure);
    await localDataCrypto.init();
    final authService = AuthService(
      secure,
      prefs,
      ProfileService(prefs, localDataCrypto),
      crypto,
      keyStore,
      localDataCrypto,
    );

    await authService.reconcileReinstall();

    expect(await authService.isSignedIn, isTrue);
    expect(await secure.read('ahoy_user_id'), 'current-id');
  });

  test('keychain accessibility migration is a safe no-op off iOS', () async {
    FlutterSecureStorage.setMockInitialValues({
      'ahoy_user_id': 'u1',
      'ahoy_private_key': 'k1',
    });
    SharedPreferences.setMockInitialValues({});
    final secure = SecureStore();
    final prefs = PrefsStore();
    await prefs.init();

    await secure.migrateAccessibility(prefs);

    // Values survive untouched on this platform and the marker is not set
    // (iOS-only migration).
    expect(await secure.read('ahoy_user_id'), 'u1');
    expect(await secure.read('ahoy_private_key'), 'k1');
  });

  test('sign in still works after conversations were quarantined', () async {
    SharedPreferences.setMockInitialValues({
      'ahoy_conversations': _corruptEnvelope,
    });
    final prefs = PrefsStore();
    await prefs.init();
    final store = ConversationStore(
      prefs,
      LocalDataCrypto.withKeyForTesting(
        Uint8List.fromList(List.generate(32, (i) => i + 1)),
      ),
    );

    // Startup, reads and writes all keep working after the quarantine.
    expect(store.loadAll(), isEmpty);
    await pumpEventQueue();
    expect(store.hasStoredData, isFalse);
    await store.upsert(
      Conversation(
        id: 'conv-2',
        peerUuid: 'peer-2',
        peerDisplayName: 'Peer',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026),
      ),
    );
    expect(store.loadAll(), hasLength(1));
  });
}
