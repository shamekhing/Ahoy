import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';

class _StoreSet {
  final PrefsStore prefs;
  final ConversationStore convStore;
  final MessageStore msgStore;
  final LocalDataCrypto localDataCrypto;

  _StoreSet._(this.prefs, this.convStore, this.msgStore, this.localDataCrypto);

  static Future<_StoreSet> create() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore();
    await prefs.init();
    final localDataCrypto = LocalDataCrypto.withKeyForTesting(
      Uint8List.fromList(List.generate(32, (i) => i)),
    );
    return _StoreSet._(
      prefs,
      ConversationStore(prefs, localDataCrypto),
      MessageStore(prefs, localDataCrypto),
      localDataCrypto,
    );
  }
}

class _CapturingTransport extends TransportManager {
  final sent = <Map<String, dynamic>>[];
  bool failSends = false;

  @override
  TransportMode currentModeFor(String peerUuid) => TransportMode.lan;

  @override
  Future<bool> send(
    String peerUuid,
    String fromUuid,
    String fromShortId,
    String fromName,
    Map<String, dynamic> data,
  ) async {
    sent.add(data);
    return !failSends;
  }
}

Future<ChatService> _service(
  _StoreSet stores,
  _CapturingTransport transport,
) async {
  final crypto = CryptoService();
  final keys = await crypto.generateKeyPair();
  crypto.activate(keys['privateKey']!, keys['publicKey']!);
  return ChatService(
    transport,
    stores.convStore,
    stores.msgStore,
    crypto,
    stores.localDataCrypto,
    null,
    stores.prefs,
  );
}

Future<void> _seedConversation(_StoreSet stores) {
  return stores.convStore.upsert(
    Conversation(
      id: MessageStore.conversationId(_myUuid, _peerUuid),
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      lastTransport: TransportMode.lan,
      createdAt: DateTime.utc(2026),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  setUpAll(() async {
    docsDir = await Directory.systemTemp.createTemp('ahoy_orphan_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => docsDir.path);
  });

  tearDownAll(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await docsDir.delete(recursive: true);
  });

  test('orphaned sending messages are failed when no outbox backs them',
      () async {
    final stores = await _StoreSet.create();
    await _seedConversation(stores);
    final convId = MessageStore.conversationId(_myUuid, _peerUuid);
    await stores.msgStore.addMessage(
      Message(
        id: 'orphan-1',
        conversationId: convId,
        senderId: _myUuid,
        type: MessageType.text,
        content: 'never sent',
        status: MessageStatus.sending,
        transport: TransportMode.lan,
        timestamp: DateTime.utc(2026),
      ),
    );

    final service = await _service(stores, _CapturingTransport());
    await service.failOrphanedSends();

    final stored =
        stores.msgStore.loadMessages(convId).firstWhere((m) => m.id == 'orphan-1');
    expect(stored.status, MessageStatus.failed);
  });

  test('a persisted outbox entry survives a restart and retries on return',
      () async {
    final stores = await _StoreSet.create();
    await _seedConversation(stores);
    final convId = MessageStore.conversationId(_myUuid, _peerUuid);

    // Session one: the transport is down, so the keyless send is queued.
    final failing = _CapturingTransport()..failSends = true;
    final serviceA = await _service(stores, failing);
    final queued = await serviceA.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.text,
      content: 'hello',
      myPublicKeyPEM: null,
      peerPublicKeyPEM: null,
    );
    expect(queued.status, MessageStatus.sending);
    expect(serviceA.hasPendingFor(_peerUuid), isTrue);

    // Session two: a fresh service over the same stores restores the queue.
    final delivering = _CapturingTransport();
    final serviceB = await _service(stores, delivering);
    await serviceB.restoreOutbox();
    expect(serviceB.hasPendingFor(_peerUuid), isTrue);

    // The restored entry keeps its message out of the orphan sweep.
    await serviceB.failOrphanedSends();
    final stillWaiting = stores.msgStore
        .loadMessages(convId)
        .firstWhere((m) => m.id == queued.id);
    expect(stillWaiting.status, MessageStatus.sending);

    // The peer returns with a signed identity and the message is delivered.
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    final identity = <String, dynamic>{
      'msgType': 'identity',
      'senderUuid': _peerUuid,
      'senderShortId': 'PEER12',
      'senderName': 'Peer',
      'senderPublicKeyPEM': peerKeys['publicKey'],
      'timestamp': DateTime.now().toIso8601String(),
    };
    identity['signature'] = peerCrypto.signPayload(jsonEncode({
      'msgType': identity['msgType'],
      'senderUuid': identity['senderUuid'],
      'senderShortId': identity['senderShortId'],
      'senderName': identity['senderName'],
      'senderPublicKeyPEM': identity['senderPublicKeyPEM'],
      'timestamp': identity['timestamp'],
    }));
    await serviceB.onInboundPacket(
      rawPayload: jsonEncode(identity),
      peerUuid: _peerUuid,
      peerShortId: 'PEER12',
      peerDisplayName: 'Peer',
      myUuid: _myUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    final chat = delivering.sent.where((p) => p['v'] == 3).toList();
    expect(chat, hasLength(1));
    final inner = jsonDecode(
      peerCrypto.decryptFromPeer(chat.single['ct'] as String),
    ) as Map<String, dynamic>;
    expect(inner['content'], 'hello');
    expect(
      stores.msgStore
          .loadMessages(convId)
          .firstWhere((m) => m.id == queued.id)
          .status,
      MessageStatus.sent,
    );
  });

  test('a queued media message whose source is gone is failed on restart',
      () async {
    final stores = await _StoreSet.create();
    await _seedConversation(stores);
    final convId = MessageStore.conversationId(_myUuid, _peerUuid);

    final failing = _CapturingTransport()..failSends = true;
    final serviceA = await _service(stores, failing);
    final source = File(
      '${Directory.systemTemp.path}/ahoy_voice_orphan_test.aac',
    );
    await source.writeAsBytes(List.generate(32, (i) => i), flush: true);
    final queued = await serviceA.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.voice,
      content: source.path,
      myPublicKeyPEM: null,
      peerPublicKeyPEM: null,
    );
    expect(serviceA.hasPendingFor(_peerUuid), isTrue);

    // The recorder temp is consumed on queue; nothing is left to retry.
    final delivering = _CapturingTransport();
    final serviceB = await _service(stores, delivering);
    await serviceB.restoreOutbox();
    expect(serviceB.hasPendingFor(_peerUuid), isFalse);
    await serviceB.failOrphanedSends();
    expect(
      stores.msgStore
          .loadMessages(convId)
          .firstWhere((m) => m.id == queued.id)
          .status,
      MessageStatus.failed,
    );
  });
}

