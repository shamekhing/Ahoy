import 'dart:typed_data';

import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/maintenance/local_data_migrator.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the migration runs once and the marker skips later launches',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final localDataCrypto = LocalDataCrypto.withKeyForTesting(
      Uint8List.fromList(List.generate(32, (i) => i)),
    );
    final profileService = ProfileService(prefs, localDataCrypto);
    final migrator = LocalDataMigrator(
      profileService,
      ConversationStore(prefs, localDataCrypto),
      MessageStore(prefs, localDataCrypto),
      localDataCrypto,
      null,
      prefs,
    );

    await migrator.migrate();
    expect(migrator.debugMigrationsRun, 1);
    expect(prefs.getBool('ahoy_local_data_migrated'), isTrue);

    // A second launch (new migrator, same stores) skips the work entirely.
    final second = LocalDataMigrator(
      profileService,
      ConversationStore(prefs, localDataCrypto),
      MessageStore(prefs, localDataCrypto),
      localDataCrypto,
      null,
      prefs,
    );
    await second.migrate();
    expect(second.debugMigrationsRun, 1);
  });
}
