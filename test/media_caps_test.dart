import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/core/errors.dart';
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

late Directory docsDir;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    docsDir = await Directory.systemTemp.createTemp('ahoy_media_caps_test');
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

  test('oversized inbound media is dropped and existing media stays intact',
      () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);

    // Seed one owned media file via a normal send.
    final seedBytes = Uint8List.fromList(List.generate(64, (i) => i));
    final seedFile = File(
      '${docsDir.path}/image_picker_seed.jpg',
    );
    await seedFile.writeAsBytes(seedBytes, flush: true);
    await harness.service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.image,
      content: seedFile.path,
      myPublicKeyPEM: harness.myPublicKeyPEM,
      peerPublicKeyPEM: peerKeys['publicKey'],
    );
    final storedBefore = harness
        .msgStore.loadMessages(MessageStore.conversationId(_myUuid, _peerUuid))
        .single;
    expect(storedBefore.type, MessageType.image);

    // Now anything above 100 bytes is refused.
    harness.service.debugMediaLimits(maxBytes: 100);
    final oversized = Uint8List.fromList(List.generate(200, (i) => i));
    final payload = await _sealedInbound(
      harness,
      peerCrypto,
      peerKeys['publicKey']!,
      content: base64.encode(oversized),
    );
    final result = await harness.service.onInboundPacket(
      rawPayload: jsonEncode(payload),
      peerUuid: _peerUuid,
      peerShortId: 'PEER12',
      peerDisplayName: 'Peer',
      myUuid: _myUuid,
      transport: TransportMode.lan,
      receiveOff: false,
      blockedUuids: const {},
    );

    expect(result, isNull);
    final stored = harness.msgStore
        .loadMessages(MessageStore.conversationId(_myUuid, _peerUuid));
    expect(stored, hasLength(1),
        reason: 'the refused message is not stored');
    expect(
      harness.localDataCrypto.readEncryptedFileSync(File(storedBefore.content)),
      seedBytes,
      reason: 'existing media is untouched by the refusal',
    );
  });

  test('an oversized outbound media file fails visibly', () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    harness.service.debugMediaLimits(maxBytes: 10);
    final big = File('${docsDir.path}/image_picker_big.jpg');
    await big.writeAsBytes(List.generate(50, (i) => i), flush: true);

    await expectLater(
      harness.service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.image,
        content: big.path,
        myPublicKeyPEM: harness.myPublicKeyPEM,
        peerPublicKeyPEM: peerKeys['publicKey'],
      ),
      throwsA(
        isA<TransportError>().having(
          (e) => e.reason,
          'reason',
          'Media file is too large to send',
        ),
      ),
    );
    expect(
      harness.msgStore.loadMessages(
        MessageStore.conversationId(_myUuid, _peerUuid),
      ),
      isEmpty,
      reason: 'a refused send stores nothing',
    );
  });

  test('quota refusal leaves existing media intact', () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);

    final seedBytes = Uint8List.fromList(List.generate(800, (i) => i % 256));
    final seedFile = File('${docsDir.path}/image_picker_quota.jpg');
    await seedFile.writeAsBytes(seedBytes, flush: true);
    final first = await harness.service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.image,
      content: seedFile.path,
      myPublicKeyPEM: harness.myPublicKeyPEM,
      peerPublicKeyPEM: peerKeys['publicKey'],
    );

    // The quota is nearly full: anything larger is refused.
    harness.service.debugMediaLimits(quotaBytes: 1000);
    final tooBig = File('${docsDir.path}/image_picker_toolarge.jpg');
    await tooBig.writeAsBytes(List.generate(400, (i) => i), flush: true);
    await expectLater(
      harness.service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.image,
        content: tooBig.path,
        myPublicKeyPEM: harness.myPublicKeyPEM,
        peerPublicKeyPEM: peerKeys['publicKey'],
      ),
      throwsA(
        isA<TransportError>().having(
          (e) => e.reason,
          'reason',
          'Media storage quota is full',
        ),
      ),
    );

    expect(
      harness.localDataCrypto.readEncryptedFileSync(File(first.content)),
      seedBytes,
    );
  });
}

/// Builds a sealed v3 inbound payload signed by [peerCrypto].
Future<String> _sealedInbound(
  _Harness harness,
  CryptoService peerCrypto,
  String peerPublicKeyPEM, {
  required String content,
}) async {
  final inner = <String, dynamic>{
    'msgType': 'chat',
    'msgId': 'aaaaaaaa-1111-2222-3333-444444444444',
    'convId': MessageStore.conversationId(_myUuid, _peerUuid),
    'senderUuid': _peerUuid,
    'senderShortId': 'PEER12',
    'senderName': 'Peer',
    'type': MessageType.voice.name,
    'content': content,
    'replyToId': null,
    'replyToPreview': null,
    'timestamp': DateTime.now().toIso8601String(),
    'senderPublicKeyPEM': peerPublicKeyPEM,
  };
  inner['signature'] = peerCrypto.signPayload(_signatureMaterialV3(inner));
  return jsonEncode({
    'v': 3,
    'ct': peerCrypto.encryptForPeer(
      jsonEncode(inner),
      harness.myPublicKeyPEM,
    ),
  });
}

String _signatureMaterialV3(Map<String, dynamic> payload) {
  return jsonEncode({
    'msgType': payload['msgType'],
    'msgId': payload['msgId'],
    'convId': payload['convId'],
    'senderUuid': payload['senderUuid'],
    'senderShortId': payload['senderShortId'],
    'senderName': payload['senderName'],
    'type': payload['type'],
    'content': payload['content'],
    'replyToId': payload['replyToId'],
    'replyToPreview': payload['replyToPreview'],
    'timestamp': payload['timestamp'],
    'senderPublicKeyPEM': payload['senderPublicKeyPEM'],
  });
}

class _Harness {
  final _CapturingTransport transport;
  final ConversationStore convStore;
  final MessageStore msgStore;
  final ChatService service;
  final LocalDataCrypto localDataCrypto;
  final String myPublicKeyPEM;

  const _Harness({
    required this.transport,
    required this.convStore,
    required this.msgStore,
    required this.service,
    required this.localDataCrypto,
    required this.myPublicKeyPEM,
  });
}

Future<_Harness> _createHarness() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  final convStore = ConversationStore(prefs);
  final msgStore = MessageStore(prefs);
  final crypto = CryptoService();
  final keys = await crypto.generateKeyPair();
  crypto.activate(keys['privateKey']!, keys['publicKey']!);
  final localDataCrypto = LocalDataCrypto.withKeyForTesting(
    Uint8List.fromList(List.generate(32, (i) => i)),
  );
  final transport = _CapturingTransport();
  final service = ChatService(
    transport,
    convStore,
    msgStore,
    crypto,
    localDataCrypto,
  );
  return _Harness(
    transport: transport,
    convStore: convStore,
    msgStore: msgStore,
    service: service,
    localDataCrypto: localDataCrypto,
    myPublicKeyPEM: keys['publicKey']!,
  );
}

class _CapturingTransport extends TransportManager {
  final sent = <Map<String, dynamic>>[];

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
    return true;
  }
}
