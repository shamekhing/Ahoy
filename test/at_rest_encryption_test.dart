import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
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
    expect(await crypto.readEncryptedFile(file), bytes);
  });
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
