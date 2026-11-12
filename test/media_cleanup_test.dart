import 'dart:io';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';

late Directory docsDir;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    docsDir = await Directory.systemTemp.createTemp('ahoy_media_test');
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

  test('picker images in the temp directory are deleted after a send',
      () async {
    final harness = await _createHarness();
    final peerCrypto = CryptoService();
    final peerKeys = await peerCrypto.generateKeyPair();
    peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    final imageBytes = Uint8List.fromList(List.generate(128, (i) => i));
    final pickerFile = File(
      '${docsDir.path}/image_picker_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await pickerFile.writeAsBytes(imageBytes, flush: true);

    final message = await harness.service.sendMessage(
      myUuid: _myUuid,
      myShortId: 'ME1234',
      myDisplayName: 'Me',
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      type: MessageType.image,
      content: pickerFile.path,
      myPublicKeyPEM: harness.myPublicKeyPEM,
      peerPublicKeyPEM: peerKeys['publicKey'],
    );

    expect(pickerFile.existsSync(), isFalse,
        reason: 'the plaintext picker copy must not survive the send (M-5)');
    expect(message.content, endsWith('.jpg.ahoyenc'));
    expect(harness.localDataCrypto.readEncryptedFileSync(File(message.content)),
        imageBytes);
  });

  test('sign out sweeps plaintext temp files and encrypted leftovers',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
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

    final encrypted = File('${docsDir.path}/ahoy_media_old.jpg.ahoyenc');
    final pickerCopy = File('${docsDir.path}/image_picker_old.jpg');
    final voiceTemp = File('${docsDir.path}/ahoy_voice_old.aac');
    final playbackTemp = File('${docsDir.path}/ahoy_audio_old.aac');
    final unrelated = File('${docsDir.path}/unrelated.txt');
    for (final f in [encrypted, pickerCopy, voiceTemp, playbackTemp, unrelated]) {
      await f.writeAsString('x', flush: true);
    }

    await authService.signOut(onTransportStop: () async {});

    expect(encrypted.existsSync(), isFalse);
    expect(pickerCopy.existsSync(), isFalse);
    expect(voiceTemp.existsSync(), isFalse);
    expect(playbackTemp.existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue,
        reason: 'files we do not own are never touched');
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
