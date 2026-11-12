import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';

// At-rest crypto for stores that now require it (ninth review N-4).
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

const _convId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Message _message(String id, DateTime timestamp, {DateTime? receivedAt}) {
  return Message(
    id: id,
    conversationId: _convId,
    senderId: 'peer',
    type: MessageType.text,
    content: id,
    status: MessageStatus.sent,
    transport: TransportMode.lan,
    timestamp: timestamp,
    receivedAt: receivedAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('thread order follows the receiver clock, not the sender timestamp',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final store = MessageStore(prefs, _localCrypto);

    final now = DateTime.now();
    // B carries the most aggressive future-skewed sender timestamp but was
    // received first; A was received last despite the oldest timestamp.
    await store.addMessage(
      _message('A', now, receivedAt: now.add(const Duration(seconds: 5))),
    );
    await store.addMessage(
      _message('B', now.add(const Duration(minutes: 14)), receivedAt: now),
    );
    await store.addMessage(
      _message('C', now, receivedAt: now.add(const Duration(seconds: 2))),
    );

    expect(
      store.loadMessages(_convId).map((m) => m.id),
      ['B', 'C', 'A'],
    );
  });

  test('messages stored by older builds fall back to the sender timestamp',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final store = MessageStore(prefs, _localCrypto);

    final base = DateTime.now();
    await store.addMessage(_message('old-1', base));
    await store.addMessage(
      _message('old-2', base.add(const Duration(seconds: 1))),
    );

    final loaded = store.loadMessages(_convId);
    expect(loaded.map((m) => m.id), ['old-1', 'old-2']);
    // Round-trip: legacy rows keep a null receivedAt on the wire and disk.
    final json = loaded.first.toJson();
    expect(json.containsKey('receivedAt'), isFalse);
    expect(Message.fromJson(json).receivedAt, isNull);
  });

  test('conversation ids stay deterministic across peers (regression)', () {
    expect(
      CryptoService.conversationId('a', 'b'),
      CryptoService.conversationId('b', 'a'),
    );
  });
}
