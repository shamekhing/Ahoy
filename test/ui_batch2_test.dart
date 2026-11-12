import 'dart:convert';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/core/errors.dart';
import 'package:ahoy/Ahoy/providers/chat_provider.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/screens/discover/discover_screen.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:ahoy/Ahoy/widgets/chat/encrypted_chat_intro.dart';
import 'package:ahoy/Ahoy/widgets/chat/message_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// At-rest crypto for stores that require it (ninth review N-4).
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

/// Ninth-review follow-up, batch 2: items 6, 10 and 16 of the external
/// UI/UX review (permission banners, offline queueing with reachability,
/// encryption visibility).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('offline text queueing (UI review #10)', () {
    late _ModeTransport transport;
    late ChatService service;
    late MessageStore msgStore;
    late CryptoService peerCrypto;
    late Map<String, String> peerKeys;
    late Map<String, String> myKeys;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
      final convStore = ConversationStore(prefs, _localCrypto);
      msgStore = MessageStore(prefs, _localCrypto);
      final myCrypto = CryptoService();
      myKeys = await myCrypto.generateKeyPair();
      myCrypto.activate(myKeys['privateKey']!, myKeys['publicKey']!);
      peerCrypto = CryptoService();
      peerKeys = await peerCrypto.generateKeyPair();
      peerCrypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
      service = ChatService(
        transport,
        convStore,
        msgStore,
        myCrypto,
        _localCrypto,
        null,
        prefs,
      );
      // The peer's key is pinned through the normal first-send path.
      transport.mode = TransportMode.lan;
      await service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'first contact',
        myPublicKeyPEM: myKeys['publicKey'],
        peerPublicKeyPEM: peerKeys['publicKey'],
      );
      transport.sent.clear();
    });

    test('a text message to an offline peer queues instead of throwing',
        () async {
      transport.mode = TransportMode.none;
      final message = await service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'while you were away',
        myPublicKeyPEM: myKeys["publicKey"],
        peerPublicKeyPEM: peerKeys['publicKey'],
      );

      expect(message, isNotNull, reason: 'no exception: the text is kept');
      expect(message.status, MessageStatus.failed);
      expect(service.hasPendingFor(_peerUuid), isTrue);
      final stored = msgStore.loadMessages(
        MessageStore.conversationId(_myUuid, _peerUuid),
      );
      expect(stored.any((m) => m.content == 'while you were away'), isTrue);
    });

    test('the queued message is delivered when the peer returns', () async {
      transport.mode = TransportMode.none;
      await service.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'while you were away',
        myPublicKeyPEM: myKeys["publicKey"],
        peerPublicKeyPEM: peerKeys['publicKey'],
      );

      transport.mode = TransportMode.lan;
      final touched = await service.retryPendingFor(_peerUuid);
      expect(touched, isNotEmpty);
      final stored = msgStore.loadMessages(
        MessageStore.conversationId(_myUuid, _peerUuid),
      );
      final queued = stored.firstWhere((m) => m.content == 'while you were away');
      expect(queued.status, MessageStatus.sent);
      // The retry payload is sealed to the peer's key and decrypts to the
      // original text.
      final sealed = transport.sent.last;
      expect(sealed['v'], 3);
      final inner =
          jsonDecode(peerCrypto.decryptFromPeer(sealed['ct'] as String))
              as Map<String, dynamic>;
      expect(inner['content'], 'while you were away');
    });

    test('media to an offline peer still requires a connection', () async {
      transport.mode = TransportMode.none;
      await expectLater(
        service.sendMessage(
          myUuid: _myUuid,
          myShortId: 'ME1234',
          myDisplayName: 'Me',
          peerUuid: _peerUuid,
          peerDisplayName: 'Peer',
          peerShortId: 'PEER12',
          type: MessageType.image,
          content: 'ignored-path',
          myPublicKeyPEM: myKeys["publicKey"],
          peerPublicKeyPEM: peerKeys['publicKey'],
        ),
        throwsA(isA<TransportError>()),
      );
    });
  });

  group('offline hint in the composer (UI review #10)', () {
    Future<void> pumpBar(
      WidgetTester tester, {
      required bool peerNearby,
      required bool canSendMedia,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageInputBar(
              canSendMedia: canSendMedia,
              isRecording: false,
              peerNearby: peerNearby,
              onSendText: (_) async => true,
              onPickImage: () {},
              onCapturePhoto: () {},
              onToggleRecord: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('explains queueing when the peer is not nearby', (tester) async {
      await pumpBar(tester, peerNearby: false, canSendMedia: true);
      expect(
        find.text('Peer not nearby — messages queue until they return'),
        findsOneWidget,
      );
    });

    testWidgets('keeps the BLE-only hint when the peer is nearby',
        (tester) async {
      await pumpBar(tester, peerNearby: true, canSendMedia: false);
      expect(find.text('Text only (BLE mode)'), findsOneWidget);
    });
  });

  testWidgets('the encrypted intro renders its copy (UI review #16)',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: EncryptedChatIntro(peerName: 'Sam')),
      ),
    );
    await tester.pump();
    expect(find.text('No messages with Sam yet'), findsOneWidget);
    expect(find.textContaining('end-to-end encrypted'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  group('permission problems on Discover (UI review #6)', () {
    testWidgets('a denied permission renders a banner with a fix',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = PrefsStore();
      await prefs.init();
      final discovery = DiscoveryProvider(
        DiscoveryService(),
        TransportManager(),
        prefs,
        CryptoService(),
      );
      // The 10-second cleanup timer must not outlive the test body (widget
      // tests run in fake async and forbid pending timers).
      discovery.debugStopCleanupTimer();
      discovery.setPermissionProblems([
        'Bluetooth scanning is blocked — nearby discovery over BLE cannot run.',
      ]);

      final chat = ChatProvider(
        ChatService(
          TransportManager(),
          ConversationStore(prefs, _localCrypto),
          MessageStore(prefs, _localCrypto),
          CryptoService(),
          _localCrypto,
        ),
        ConversationStore(prefs, _localCrypto),
        MessageStore(prefs, _localCrypto),
        TransportManager(),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DiscoveryProvider>.value(value: discovery),
            ChangeNotifierProvider<ChatProvider>.value(value: chat),
          ],
          child: const MaterialApp(home: DiscoverScreen()),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('Bluetooth scanning is blocked'),
        findsOneWidget,
      );
      expect(find.text('Open settings'), findsOneWidget);
    });
  });
}
