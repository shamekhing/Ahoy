import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/local_user.dart';
import 'package:ahoy/Ahoy/models/message.dart';
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

  test('message history is encrypted in SharedPreferences', () async {
    final prefs = await _prefs();
    final crypto = _crypto();
    final store = MessageStore(prefs, crypto);
    const conversationId = 'conversation-1';

    await store.addMessage(
      Message(
        id: 'message-1',
        conversationId: conversationId,
        senderId: 'sender-1',
        type: MessageType.text,
        content: 'quiet secret',
        status: MessageStatus.sent,
        transport: TransportMode.lan,
        timestamp: DateTime.utc(2026, 1, 1),
      ),
    );

    final raw = prefs.getString('ahoy_msgs_$conversationId')!;
    expect(raw, startsWith(LocalDataCrypto.encryptedValuePrefix));
    expect(raw, isNot(contains('quiet secret')));

    final loaded = store.loadMessages(conversationId).single;
    expect(loaded.content, 'quiet secret');
  });

  test('conversation previews are encrypted in SharedPreferences', () async {
    final prefs = await _prefs();
    final crypto = _crypto();
    final store = ConversationStore(prefs, crypto);

    await store.upsert(
      Conversation(
        id: 'conversation-1',
        peerUuid: 'peer-1',
        peerDisplayName: 'Peer',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026, 1, 1),
        lastMessagePreview: 'preview secret',
      ),
    );

    final raw = prefs.getString(AhoyConstants.prefConversations)!;
    expect(raw, startsWith(LocalDataCrypto.encryptedValuePrefix));
    expect(raw, isNot(contains('preview secret')));

    final loaded = store.loadAll().single;
    expect(loaded.lastMessagePreview, 'preview secret');
  });

  test('media files are encrypted on disk and can be read back', () async {
    final crypto = _crypto();
    final dir = await Directory.systemTemp.createTemp('ahoy_crypto_test_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File(
      '${dir.path}/media.jpg${LocalDataCrypto.encryptedFileExtension}',
    );
    final bytes = Uint8List.fromList('media secret'.codeUnits);

    await crypto.writeEncryptedFile(file, bytes);

    final raw = await file.readAsString();
    expect(raw, startsWith(LocalDataCrypto.encryptedValuePrefix));
    expect(raw, isNot(contains('media secret')));
    expect(await crypto.readEncryptedFile(file), orderedEquals(bytes));
  });

  test('profile data is encrypted in SharedPreferences', () async {
    final prefs = await _prefs();
    final crypto = _crypto();
    final service = ProfileService(prefs, crypto);

    await service.saveProfile(
      _user(username: 'quiet captain', bio: 'harbor secret'),
    );

    final raw = prefs.getString(AhoyConstants.prefProfile)!;
    expect(raw, startsWith(LocalDataCrypto.encryptedValuePrefix));
    expect(raw, isNot(contains('quiet captain')));
    expect(raw, isNot(contains('harbor secret')));

    final loaded = service.loadProfile()!;
    expect(loaded.username, 'quiet captain');
    expect(loaded.bio, 'harbor secret');
  });

  test(
    'legacy plaintext prefs and media are migrated to encrypted storage',
    () async {
      final crypto = _crypto();
      final dir = await Directory.systemTemp.createTemp('ahoy_migration_test_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final legacyMedia = File('${dir.path}/legacy_media.jpg');
      final legacyMediaBytes = Uint8List.fromList(
        'legacy media secret'.codeUnits,
      );
      await legacyMedia.writeAsBytes(legacyMediaBytes);

      final conversation = Conversation(
        id: 'conversation-1',
        peerUuid: 'peer-1',
        peerDisplayName: 'Peer',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026, 1, 1),
        lastMessagePreview: 'legacy preview secret',
      );
      final message = Message(
        id: 'message-1',
        conversationId: conversation.id,
        senderId: 'peer-1',
        type: MessageType.image,
        content: legacyMedia.path,
        status: MessageStatus.sent,
        transport: TransportMode.lan,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      SharedPreferences.setMockInitialValues({
        AhoyConstants.prefProfile: jsonEncode(
          _user(username: 'legacy profile secret').toJson(),
        ),
        AhoyConstants.prefConversations: jsonEncode([conversation.toJson()]),
        '${MessageStore.messageKeyPrefix}${conversation.id}': jsonEncode([
          message.toJson(),
        ]),
      });
      final prefs = PrefsStore();
      await prefs.init();
      final profile = ProfileService(prefs, crypto, () async => dir);
      final conversations = ConversationStore(prefs, crypto);
      final messages = MessageStore(prefs, crypto);

      await LocalDataMigrator(
        profile,
        conversations,
        messages,
        crypto,
        () async => dir,
      ).migrate();

      final rawProfile = prefs.getString(AhoyConstants.prefProfile)!;
      final rawConversations = prefs.getString(
        AhoyConstants.prefConversations,
      )!;
      final rawMessages = prefs.getString(
        '${MessageStore.messageKeyPrefix}${conversation.id}',
      )!;
      expect(rawProfile, startsWith(LocalDataCrypto.encryptedValuePrefix));
      expect(
        rawConversations,
        startsWith(LocalDataCrypto.encryptedValuePrefix),
      );
      expect(rawMessages, startsWith(LocalDataCrypto.encryptedValuePrefix));
      expect(rawProfile, isNot(contains('legacy profile secret')));
      expect(rawConversations, isNot(contains('legacy preview secret')));
      expect(rawMessages, isNot(contains('legacy media secret')));

      final migratedMessage = messages.loadMessages(conversation.id).single;
      expect(
        migratedMessage.content,
        endsWith(LocalDataCrypto.encryptedFileExtension),
      );
      expect(
        await crypto.readEncryptedFile(File(migratedMessage.content)),
        orderedEquals(legacyMediaBytes),
      );
    },
  );
}

Future<PrefsStore> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  return prefs;
}

LocalDataCrypto _crypto() {
  return LocalDataCrypto.withKeyForTesting(
    Uint8List.fromList(List.filled(32, 7)),
  );
}

LocalUser _user({String username = 'User', String? bio, String? avatarPath}) {
  return LocalUser(
    id: 'user-1',
    username: username,
    bio: bio,
    gender: Gender.unspecified,
    avatarPath: avatarPath,
    interests: const [],
    publicKeyPEM: 'public-key',
    shortId: 'ABC123',
    createdAt: DateTime.utc(2026, 1, 1),
  );
}
