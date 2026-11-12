import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/core/errors.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
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

  Future<({AuthService auth, PrefsStore prefs, LocalDataCrypto localDataCrypto})>
      createAuth() async {
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
    final auth = AuthService(
      secure,
      prefs,
      profileService,
      crypto,
      keyStore,
      localDataCrypto,
    );
    return (auth: auth, prefs: prefs, localDataCrypto: localDataCrypto);
  }

  test('sign up with no existing account succeeds', () async {
    final created = await createAuth();
    final auth = created.auth;

    final user = await auth.signUp(
      username: 'First',
      password: 'password1',
    );

    expect(user.username, 'First');
    expect(user.publicKeyPEM, isNotEmpty);
  });

  test('a second sign up is refused unless explicitly confirmed', () async {
    final created = await createAuth();
    final auth = created.auth;
    await auth.signUp(
      username: 'First',
      password: 'password1',
    );

    // The naive path taken by the sign-in screen link must not replace the
    // existing identity (audit M-2).
    await expectLater(
      auth.signUp(
        username: 'Second',
        password: 'password1',
      ),
      throwsA(isA<AuthFailed>()),
    );

    // The refused attempt must not have touched key material or profile: the
    // original password still signs in.
    expect(await auth.signIn(password: 'password1'), isNotNull);
  });

  test('explicit confirmation replaces the identity', () async {
    final created = await createAuth();
    final auth = created.auth;
    final first = await auth.signUp(
      username: 'First',
      password: 'password1',
    );

    // A conversation from the old identity must not survive the replacement.
    final convStore = ConversationStore(
      created.prefs,
      created.localDataCrypto,
    );
    await convStore.upsert(
      Conversation(
        id: 'conv-old',
        peerUuid: 'peer-1',
        peerDisplayName: 'Old Peer',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026),
      ),
    );

    final second = await auth.signUp(
      username: 'Second',
      password: 'password2',
      replaceExisting: true,
    );

    expect(second.id, isNot(first.id));
    expect(second.publicKeyPEM, isNot(first.publicKeyPEM));
    expect(await auth.signIn(password: 'password2'), isNotNull);
    await expectLater(
      auth.signIn(password: 'password1'),
      throwsA(isA<AuthFailed>()),
    );
    expect(convStore.loadAll(), isEmpty,
        reason: 'the confirmed replacement clears the old identity data');
  });
}

