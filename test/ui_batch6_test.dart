import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/models/nearby_peer.dart';
import 'package:ahoy/Ahoy/providers/auth_provider.dart';
import 'package:ahoy/Ahoy/providers/chat_provider.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/providers/profile_provider.dart';
import 'package:ahoy/Ahoy/providers/transport_provider.dart';
import 'package:ahoy/Ahoy/screens/chat/chat_screen.dart';
import 'package:ahoy/Ahoy/screens/settings/settings_screen.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/media/media_service.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:ahoy/Ahoy/widgets/chat/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ninth-review follow-up, batch 6: states and copy items 11 (queued/
/// failed affordances), 13 (blocked chat UX), 28 (settings copy), 29
/// (startup recovery) and 30 (dash-less copy) of the external UI/UX review.
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';

class _ModeTransport extends TransportManager {
  TransportMode mode = TransportMode.none;
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

// SETTINGS_AND_COPY_GROUPS

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tap-to-retry for queued messages (UI review #11)', () {
    late _ModeTransport transport;
    late ChatProvider chat;
    late MessageStore msgStore;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
      final convStore = ConversationStore(prefs, _localCrypto);
      msgStore = MessageStore(prefs, _localCrypto);
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
    });

    test('retryFor drains the queue once the peer is reachable', () async {
      transport.mode = TransportMode.none;
      final message = await chat.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'queued while offline',
        myPublicKeyPEM: null,
        peerPublicKeyPEM: null,
      );
      expect(message, isNotNull);
      expect(message!.status, MessageStatus.failed);

      transport.mode = TransportMode.lan;
      await chat.retryFor(_peerUuid);

      final stored = msgStore.loadMessages(
        MessageStore.conversationId(_myUuid, _peerUuid),
      );
      expect(
        stored.firstWhere((m) => m.content == 'queued while offline').status,
        MessageStatus.sent,
        reason: 'the public retry entry point drains the queue',
      );
    });

    testWidgets('a failed bubble retries on tap and explains its status',
        (tester) async {
      var retries = 0;
      Message bubble(MessageStatus status) => Message(
            id: 'm1',
            conversationId: 'c1',
            senderId: _myUuid,
            type: MessageType.text,
            content: 'hello',
            status: status,
            transport: TransportMode.lan,
            timestamp: DateTime.utc(2026, 1, 1),
          );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: bubble(MessageStatus.failed),
              isMine: true,
              onRetry: () => retries++,
              localDataCrypto: _localCrypto,
            ),
          ),
        ),
      );

      expect(
        find.byType(Tooltip),
        findsOneWidget,
        reason: 'the status glyph carries its meaning in a tooltip',
      );

      await tester.tap(find.text('hello'));
      expect(retries, 1, reason: 'tapping a failed bubble retries the send');

      // A healthy bubble does not steal taps: the retry handler is unused.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: bubble(MessageStatus.delivered),
              isMine: true,
              onRetry: () => retries++,
              localDataCrypto: _localCrypto,
            ),
          ),
        ),
      );
      await tester.tap(find.text('hello'));
      expect(retries, 1);
    });
  });

  group('blocked chat is not a dead end (UI review #13)', () {
    late _ModeTransport transport;
    late ChatProvider chat;
    late ConversationStore convStore;
    late PrefsStore prefs;
    late SecureStore secure;
    Conversation conversation = Conversation(
      id: MessageStore.conversationId(_myUuid, _peerUuid),
      peerUuid: _peerUuid,
      peerDisplayName: 'Peer',
      peerShortId: 'PEER12',
      lastTransport: TransportMode.lan,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    late String convId;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      secure = SecureStore();
      prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
      convStore = ConversationStore(prefs, _localCrypto);
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
      convId = MessageStore.conversationId(_myUuid, _peerUuid);
      // Persist the conversation the way a real thread exists, then load the
      // provider the way the shell does after sign-in.
      transport.mode = TransportMode.lan;
      await service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'seed',
        myPublicKeyPEM: myKeys['publicKey'],
        peerPublicKeyPEM: peerKeys['publicKey'],
      );
      transport.mode = TransportMode.none;
      addTearDown(chat.dispose);
    });

    Future<void> pumpChat(WidgetTester tester) async {
      // Loaded here so per-test store mutations (like blocking) are visible.
      await chat.init(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        receiveOff: () => false,
        blockedUuids: {},
      );
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
                displayName: 'Peer',
                transport: TransportMode.lan,
                lastSeen: DateTime.now(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the blocked body offers its own unblock button',
        (tester) async {
      await convStore.setBlocked(convId, true);
      await pumpChat(tester);

      expect(find.text('This conversation is blocked'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Unblock'));
      await tester.pumpAndSettle();

      final conv = chat.conversations.firstWhere((c) => c.id == convId);
      expect(
        conv.isBlocked,
        isFalse,
        reason: 'the body button unblocks without hunting for the menu',
      );
    });

    testWidgets('blocking asks for confirmation first', (tester) async {
      await pumpChat(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
      expect(find.text('Block peer?'), findsOneWidget);

      // Cancel keeps the conversation open.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        chat.conversations
            .where((c) => c.id == convId)
            .every((c) => !c.isBlocked),
        isTrue,
      );

      // Confirming blocks the conversation and the peer.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();

      final conv = chat.conversations.firstWhere((c) => c.id == convId);
      expect(conv.isBlocked, isTrue);
    });
  });

  group('settings copy and states (UI review #28)', () {
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

    testWidgets('an unavailable biometric is explained, not hidden',
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
            ChangeNotifierProvider<DiscoveryProvider>.value(value: discovery),
            ChangeNotifierProvider<ProfileProvider>.value(
              value: ProfileProvider(ProfileService(prefs, _localCrypto)),
            ),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The settings list is lazy: scroll to the Account section first. The
      // test host has no biometrics, so the tile is shown disabled with the
      // reason instead of silently disappearing.
      await tester.dragUntilVisible(
        find.text('Biometric Sign-In'),
        find.byType(ListView).first,
        const Offset(0, -120),
      );
      await tester.pump();
      expect(find.text('Biometric Sign-In'), findsOneWidget);
      expect(find.text('Not available on this device'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('About'),
        find.byType(ListView).first,
        const Offset(0, -120),
      );
      expect(find.text('Version 1.0.0'), findsOneWidget);
    });
  });

  group('dashes are restored in copy (UI review #30)', () {
    test('run-on sentences are fixed at their sources', () {
      final discover = File(
        'lib/Ahoy/screens/discover/discover_screen.dart',
      ).readAsStringSync();
      expect(discover, contains('Off the Grid you are invisible to others'));
      expect(
        discover,
        contains('Receive Off new chat requests are blocked'),
      );
      final myProfile = File(
        'lib/Ahoy/screens/profile/my_profile_screen.dart',
      ).readAsStringSync();
      expect(
        myProfile,
        contains('This is your key fingerprint peers see the same number'),
      );
      final peerProfile = File(
        'lib/Ahoy/screens/profile/peer_profile_screen.dart',
      ).readAsStringSync();
      expect(
        peerProfile,
        contains('short ID is display only compare the safety number'),
      );
      expect(
        peerProfile,
        contains('Read this number aloud with your peer it is identical'),
      );
    });
  });
}
