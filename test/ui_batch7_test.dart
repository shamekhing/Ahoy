import 'dart:io';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/models/nearby_peer.dart';
import 'package:ahoy/Ahoy/providers/auth_provider.dart';
import 'package:ahoy/Ahoy/providers/chat_provider.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/providers/transport_provider.dart';
import 'package:ahoy/Ahoy/screens/auth/sign_up_screen.dart';
import 'package:ahoy/Ahoy/screens/chat/chat_screen.dart';
import 'package:ahoy/Ahoy/screens/chat/conversations_screen.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/media/media_service.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ninth-review follow-up, batch 7: form and list correctness items 19
/// (sign-up hardening), 24 (app bar title overflow) and 26 (conversation
/// list previews) of the external UI/UX review.
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';

class _ModeTransport extends TransportManager {
  TransportMode mode = TransportMode.lan;
  final sent = <Map<String, dynamic>>[];

  @override
  TransportMode currentModeFor(String peerUuid) => mode;

  @override
  Future<bool> send(
    String peerUuid,
    String fromUuid,
    String fromShortId,
    String fromName,
    Map<String, dynamic> data,
  ) async {
    sent.add(data);
    return mode != TransportMode.none;
  }
}

late Directory docsDir;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    docsDir = await Directory.systemTemp.createTemp('ahoy_ui_batch7');
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

  group('conversation previews use friendly labels (UI review #26)', () {
    late _ModeTransport transport;
    late ChatService service;
    late ConversationStore convStore;
    late CryptoService myCrypto;
    late Map<String, String> myKeys;
    late Map<String, String> peerKeys;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
      convStore = ConversationStore(prefs, _localCrypto);
      final msgStore = MessageStore(prefs, _localCrypto);
      myCrypto = CryptoService();
      myKeys = await myCrypto.generateKeyPair();
      myCrypto.activate(myKeys['privateKey']!, myKeys['publicKey']!);
      final peerCrypto = CryptoService();
      peerKeys = await peerCrypto.generateKeyPair();
      service = ChatService(
        transport,
        convStore,
        msgStore,
        myCrypto,
        _localCrypto,
        null,
        prefs,
      );
      service.registerVerifiedPeerKey(_peerUuid, peerKeys['publicKey']!);
    });

    Future<Message> send(MessageType type, String content) =>
        service.sendMessage(
          myUuid: _myUuid,
          myShortId: 'ME1234',
          myDisplayName: 'Me',
          peerUuid: _peerUuid,
          peerDisplayName: 'Peer',
          peerShortId: 'PEER12',
          type: type,
          content: content,
          myPublicKeyPEM: myKeys['publicKey'],
          peerPublicKeyPEM: peerKeys['publicKey'],
        );

    String preview() => convStore.loadAll().first.lastMessagePreview ?? '';

    test('an image message previews as [Photo], not the raw enum', () async {
      final picker = File(
        '${docsDir.path}/image_picker_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await picker.writeAsBytes(Uint8List.fromList([1, 2, 3]), flush: true);
      await send(MessageType.image, picker.path);
      expect(preview(), '[Photo]');
    });

    test('a voice message previews as [Voice message]', () async {
      final recording = File(
        '${docsDir.path}/ahoy_voice_${DateTime.now().microsecondsSinceEpoch}.aac',
      );
      await recording.writeAsBytes(Uint8List.fromList([4, 5]), flush: true);
      await send(MessageType.voice, recording.path);
      expect(preview(), '[Voice message]');
    });

    test('text previews stay verbatim', () async {
      await send(MessageType.text, 'plain words');
      expect(preview(), 'plain words');
    });
  });

  group('blocked and empty threads keep their row description (UI review #26)',
      () {
    late _ModeTransport transport;
    late ChatProvider chat;
    late ConversationStore convStore;
    late PrefsStore prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
      convStore = ConversationStore(prefs, _localCrypto);
      final msgStore = MessageStore(prefs, _localCrypto);
      final myCrypto = CryptoService();
      final myKeys = await myCrypto.generateKeyPair();
      myCrypto.activate(myKeys['privateKey']!, myKeys['publicKey']!);
      final service = ChatService(
        transport,
        convStore,
        msgStore,
        myCrypto,
        _localCrypto,
        null,
        prefs,
      );
      chat = ChatProvider(service, convStore, msgStore, transport);
      addTearDown(chat.dispose);
    });

    Conversation conversation(String uuid, String name, String shortId) =>
        Conversation(
          id: MessageStore.conversationId(_myUuid, uuid),
          peerUuid: uuid,
          peerDisplayName: name,
          peerShortId: shortId,
          lastTransport: TransportMode.lan,
          createdAt: DateTime.utc(2026, 1, 1),
        );

    Future<void> pumpList(WidgetTester tester) async {
      await chat.init(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        receiveOff: () => false,
        blockedUuids: {},
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: chat,
          child: const MaterialApp(home: ConversationsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a blocked thread shows [Blocked] even with no messages',
        (tester) async {
      await convStore.upsert(
        conversation(_peerUuid, 'Peer', 'PEER12').copyWith(isBlocked: true),
      );
      await pumpList(tester);

      expect(find.text('[Blocked]'), findsOneWidget);
    });

    testWidgets('a fresh thread without messages says so', (tester) async {
      await convStore.upsert(conversation(_peerUuid, 'Peer', 'PEER12'));
      await pumpList(tester);

      expect(find.text('No messages yet'), findsOneWidget);
    });
  });

  group('sign-up asks for confirmation and warns (UI review #19)', () {
    late SecureStore secure;
    late PrefsStore prefs;
    late _ModeTransport transport;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      secure = SecureStore();
      prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
    });

    testWidgets('mismatched confirmation blocks submission and the loss '
        'warning is visible', (tester) async {
      final crypto = CryptoService();
      final auth = AuthProvider(
        AuthService(
          secure,
          prefs,
          ProfileService(prefs, _localCrypto),
          crypto,
          KeyStore(secure, crypto),
          _localCrypto,
        ),
        transport,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: MaterialApp(
            home: SignUpScreen(
              onSignIn: () {},
              onSignedUp: () async {},
            ),
          ),
        ),
      );

      // The irreversibility warning is on the form before any key exists.
      expect(find.textContaining('cannot be recovered'), findsOneWidget);
      expect(find.text('Confirm password'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display Name').first,
        'Sam',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password').first,
        'a long password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password').first,
        'a different password',
      );
      // The submit button sits below the fold in the test viewport: drag
      // until it is visible, then submit.
      await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, 'Create Account'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create Account'));
      await tester.pumpAndSettle();

      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(
        auth.isSignedIn,
        isFalse,
        reason: 'the mismatch stopped the submission',
      );
    });
  });

  group('long names do not break the app bar (UI review #24)', () {
    final longName = 'P' * 120;
    late SecureStore secure;
    late PrefsStore prefs;
    late _ModeTransport transport;
    late ChatProvider chat;
    late Conversation conversation;

    setUp(() async {
      // Key generation runs a real isolate, so it must stay out of the
      // testWidgets fake-async zone (same pattern as the other groups).
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      secure = SecureStore();
      prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
      final convStore = ConversationStore(prefs, _localCrypto);
      final msgStore = MessageStore(prefs, _localCrypto);
      final myCrypto = CryptoService();
      final myKeys = await myCrypto.generateKeyPair();
      myCrypto.activate(myKeys['privateKey']!, myKeys['publicKey']!);
      final peerCrypto = CryptoService();
      final peerKeys = await peerCrypto.generateKeyPair();
      final service = ChatService(
        transport,
        convStore,
        msgStore,
        myCrypto,
        _localCrypto,
        null,
        prefs,
      );
      service.registerVerifiedPeerKey(_peerUuid, peerKeys['publicKey']!);
      chat = ChatProvider(service, convStore, msgStore, transport);
      addTearDown(chat.dispose);
      conversation = Conversation(
        id: MessageStore.conversationId(_myUuid, _peerUuid),
        peerUuid: _peerUuid,
        peerDisplayName: longName,
        peerShortId: 'PEER12',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026, 1, 1),
      );
    });

    testWidgets('a very long peer name stays on one ellipsized line',
        (tester) async {
      final crypto = CryptoService();
      final auth = AuthProvider(
        AuthService(
          secure,
          prefs,
          ProfileService(prefs, _localCrypto),
          crypto,
          KeyStore(secure, crypto),
          _localCrypto,
        ),
        transport,
      );
      final discovery = DiscoveryProvider(
        DiscoveryService(),
        transport,
        prefs,
        CryptoService(),
      );
      discovery.debugStopCleanupTimer();
      addTearDown(discovery.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<ChatProvider>.value(value: chat),
            ChangeNotifierProvider<TransportProvider>.value(
              value: TransportProvider(transport),
            ),
            ChangeNotifierProvider<DiscoveryProvider>.value(value: discovery),
            Provider<MediaService>.value(value: MediaService(_localCrypto)),
            Provider<LocalDataCrypto>.value(value: _localCrypto),
          ],
          child: MaterialApp(
            home: ChatScreen(
              conversation: conversation,
              peer: NearbyPeer(
                uuid: _peerUuid,
                shortId: 'PEER12',
                displayName: longName,
                transport: TransportMode.lan,
                lastSeen: DateTime.now(),
              ),
            ),
          ),
        ),
      );
      // Bounded pumping: an overflow exception fires during the first
      // layout pass, and this avoids waiting on any incidental animation.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.text(longName), findsOneWidget);
    });
  });
}

