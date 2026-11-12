import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';

// At-rest crypto for stores that now require it (ninth review N-4).
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parallel conversation mutations all land and never overlap', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final store = ConversationStore(prefs, _localCrypto);
    await store.upsert(
      Conversation(
        id: 'conv-1',
        peerUuid: 'peer-1',
        peerDisplayName: 'Peer',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026),
      ),
    );

    // 20 concurrent read-modify-write cycles. Each awaits a prefs write
    // inside the critical section, so the old release-then-wake lock could
    // let a fresh caller race the woken waiter and lose an increment
    // (audit M-3). Ownership handoff makes the count exact.
    await Future.wait([
      for (var i = 0; i < 20; i++)
        store.mutateOrCreate('conv-1', (existing) {
          return existing!.copyWith(unreadCount: existing.unreadCount + 1);
        }),
    ]);

    expect(store.loadAll().single.unreadCount, 20);
    expect(store.debugMaxConcurrentEntries, 1);
  });

  test('parallel message adds all land and never overlap', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final store = MessageStore(prefs, _localCrypto);

    await Future.wait([
      for (var i = 0; i < 20; i++)
        store.addMessage(
          Message(
            id: 'msg-$i',
            conversationId: 'conv-1',
            senderId: 'peer-1',
            type: MessageType.text,
            content: 'hello $i',
            status: MessageStatus.sent,
            transport: TransportMode.lan,
            timestamp: DateTime.utc(2026, 1, 1, 0, i),
          ),
        ),
    ]);

    expect(store.loadMessages('conv-1'), hasLength(20));
    expect(store.debugMaxConcurrentEntries, 1);
  });
}
