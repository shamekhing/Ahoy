
import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/models/nearby_peer.dart';
import 'package:ahoy/Ahoy/providers/auth_provider.dart';
import 'package:ahoy/Ahoy/providers/chat_provider.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/providers/transport_provider.dart';
import 'package:ahoy/Ahoy/screens/chat/chat_screen.dart';
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
import 'package:ahoy/Ahoy/widgets/chat/message_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ninth-review follow-up, batch 8: message actions and accessibility
/// surface — items 25 (copy/delete + date chips), 31 (icon-button
/// tooltips), 34 (bounded auth forms) of the external UI/UX review.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('message long-press actions (UI review #25)', () {
    late _ModeTransport transport;
    late ChatProvider chat;
    late MessageStore msgStore;
    late PrefsStore prefs;
    late Conversation conversation;
    late String convId;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      prefs = PrefsStore();
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
      addTearDown(chat.dispose);
      convId = MessageStore.conversationId(_myUuid, _peerUuid);
      conversation = Conversation(
        id: convId,
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      // A short alternating history: even indexes are mine.
      final now = DateTime.now();
      for (var i = 0; i < 6; i++) {
        await msgStore.addMessage(
          Message(
            id: 'seed-$i',
            conversationId: convId,
            senderId: i.isEven ? _myUuid : _peerUuid,
            type: MessageType.text,
            content: 'seed message $i',
            status: MessageStatus.sent,
            transport: TransportMode.lan,
            timestamp: now.subtract(Duration(minutes: 10 - i)),
            receivedAt: now.subtract(Duration(minutes: 10 - i)),
          ),
        );
      }
    });

    Future<void> pumpChat(WidgetTester tester) async {
      await chat.init(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        receiveOff: () => false,
        blockedUuids: {},
      );
      final secure = SecureStore();
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

    testWidgets('own text messages offer reply, copy and delete',
        (tester) async {
      await pumpChat(tester);

      await tester.longPress(find.text('seed message 4'));
      await tester.pumpAndSettle();

      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.byTooltip('Conversation options'), findsOneWidget);
    });

    testWidgets('copying puts the message text on the clipboard',
        (tester) async {
      final clipboard = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pumpChat(tester);

      await tester.longPress(find.text('seed message 4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy text'));
      await tester.pumpAndSettle();

      expect(clipboard, contains('seed message 4'));
    });

    testWidgets('deleting removes the bubble and the row', (tester) async {
      await pumpChat(tester);

      await tester.longPress(find.text('seed message 4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('seed message 4'), findsNothing);
      expect(
        chat.messagesFor(convId).any((m) => m.id == 'seed-4'),
        isFalse,
      );
    });

    testWidgets('peer messages cannot be deleted', (tester) async {
      await pumpChat(tester);

      await tester.longPress(find.text('seed message 5'));
      await tester.pumpAndSettle();

      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
    });
  });

  group('date chips between day blocks (UI review #25)', () {
    late _ModeTransport transport;
    late ChatProvider chat;
    late MessageStore msgStore;
    late PrefsStore prefs;
    late SecureStore secure;
    late Conversation conversation;
    late String convId;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      secure = SecureStore();
      prefs = PrefsStore();
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
      addTearDown(chat.dispose);
      convId = MessageStore.conversationId(_myUuid, _peerUuid);
      conversation = Conversation(
        id: convId,
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final now = DateTime.now();
      await msgStore.addMessage(
        Message(
          id: 'old',
          conversationId: convId,
          senderId: _peerUuid,
          type: MessageType.text,
          content: 'from yesterday',
          status: MessageStatus.sent,
          transport: TransportMode.lan,
          timestamp: now.subtract(const Duration(days: 1)),
          receivedAt: now.subtract(const Duration(days: 1)),
        ),
      );
      await msgStore.addMessage(
        Message(
          id: 'new',
          conversationId: convId,
          senderId: _myUuid,
          type: MessageType.text,
          content: 'from today',
          status: MessageStatus.sent,
          transport: TransportMode.lan,
          timestamp: now,
          receivedAt: now,
        ),
      );
    });

    testWidgets('a day change renders a labeled chip in the transcript',
        (tester) async {
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

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      // The chip sits above the older message it labels.
      expect(
        tester.getTopLeft(find.text('Yesterday')).dy,
        lessThan(tester.getTopLeft(find.text('from yesterday')).dy),
      );
    });
  });

  group('icon-only actions are labelled (UI review #31)', () {
    testWidgets('the composer buttons carry tooltips', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageInputBar(
              canSendMedia: true,
              isRecording: false,
              onSendText: (_) async => true,
              onCancelRecording: () async {},
              onPickImage: () {},
              onCapturePhoto: () {},
              onToggleRecord: () {},
            ),
          ),
        ),
      );

      expect(find.byTooltip('Photo from gallery'), findsOneWidget);
      expect(find.byTooltip('Capture photo'), findsOneWidget);
      expect(find.byTooltip('Voice message'), findsOneWidget);
    });

  });
}

