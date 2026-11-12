import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/core/errors.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
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
    docsDir = await Directory.systemTemp.createTemp('ahoy_voice_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => docsDir.path);
  });

  tearDownAll(() async {
    await docsDir.delete(recursive: true);
  });

  test('sends voice message bytes instead of an empty payload', () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    final audioBytes = Uint8List.fromList(List.generate(512, (i) => i % 256));
    final voiceFile = await _writeTempAudio(audioBytes);

    final message = await harness.service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.voice,
      content: voiceFile.path,
      myPublicKeyPEM: harness.myPublicKeyPEM,
      peerPublicKeyPEM: peerKeys['publicKey'],
    );

    expect(message.content, endsWith('.aac.ahoyenc'));
    expect(voiceFile.existsSync(), isFalse,
        reason: 'the recorder temp file is deleted after capture');
    expect(harness.transport.sent, hasLength(1));

    final payload = harness.transport.sent.single;
    expect(payload['v'], 3);
    final inner = jsonDecode(
      peerCrypto.decryptFromPeer(payload['ct'] as String),
    ) as Map<String, dynamic>;
    expect(inner['type'], 'voice');
    expect(inner['content'], base64.encode(audioBytes),
        reason: 'the sealed payload must carry the audio bytes (audit H-1)');

    final stored = harness.localDataCrypto
        .readEncryptedFileSync(File(message.content));
    expect(stored, audioBytes);
  });

  test('a missing media source fails visibly instead of sending empty',
      () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();

    expect(
      () => harness.service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.voice,
        content: '${docsDir.path}/ahoy_voice_missing.aac',
        myPublicKeyPEM: harness.myPublicKeyPEM,
        peerPublicKeyPEM: peerKeys['publicKey'],
      ),
      throwsA(isA<TransportError>()),
    );
    expect(harness.transport.sent, isEmpty);
    expect(harness.msgStore.loadMessages(
      MessageStore.conversationId(_myUuid, _peerUuid),
    ), isEmpty);
  });

  test('keyless voice send queues the bytes and delivers them on retry',
      () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    final audioBytes = Uint8List.fromList(List.generate(64, (i) => i));
    final voiceFile = await _writeTempAudio(audioBytes);

    final message = await harness.service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.voice,
      content: voiceFile.path,
      myPublicKeyPEM: harness.myPublicKeyPEM,
      peerPublicKeyPEM: null,
    );
    expect(message.status, MessageStatus.sending);
    expect(harness.service.hasPendingFor(_peerUuid), isTrue);

    // The temp file is already gone, so only the queued bytes can deliver.
    harness.service.registerVerifiedPeerKey(_peerUuid, peerKeys['publicKey']!);
    await harness.service.retryPendingFor(_peerUuid);

    // The first send was the signed identity broadcast, the second the retry.
    final chatPayloads = harness.transport.sent
        .where((p) => p['v'] == 3)
        .toList();
    expect(chatPayloads, hasLength(1));
    final inner = jsonDecode(
      peerCrypto.decryptFromPeer(chatPayloads.single['ct'] as String),
    ) as Map<String, dynamic>;
    expect(inner['content'], base64.encode(audioBytes));
  });

  test('inbound media with empty content is dropped', () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    final convId = MessageStore.conversationId(_myUuid, _peerUuid);
    await harness.convStore.upsert(
      Conversation(
        id: convId,
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        peerPublicKeyPEM: peerKeys['publicKey'],
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026),
      ),
    );

    final payload = await _sealedInbound(
      harness,
      peerCrypto,
      peerKeys['publicKey']!,
      content: '',
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
    expect(harness.msgStore.loadMessages(convId), isEmpty);
  });
}
Future<File> _writeTempAudio(List<int> bytes) async {
  final file = File(
    '${docsDir.path}/ahoy_voice_${DateTime.now().microsecondsSinceEpoch}.aac',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
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
  final material = jsonEncode({
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
  return 'ahoy-chat-v3:$material';
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

