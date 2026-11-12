import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/conversation.dart';
import 'package:ahoy/Ahoy/models/local_user.dart';
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
import 'package:ahoy/Ahoy/widgets/chat/fullscreen_image_view.dart';
import 'package:ahoy/Ahoy/widgets/chat/message_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ninth-review follow-up, batch 4: chat polish — items 8 (bottom-anchored
/// scrolling), 9 (per-conversation errors), 14 (voice recording/playback
/// UX) and 15 (fullscreen images) of the external UI/UX review.
final _localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));

const _myUuid = '11111111-1111-4111-8111-111111111111';
const _peerUuid = '22222222-2222-4222-8222-222222222222';
const _otherUuid = '33333333-3333-4333-8333-333333333333';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('errors are scoped per conversation (UI review #9)', () {
    late _ModeTransport transport;
    late ChatProvider chat;
    late ChatService service;
    late PrefsStore prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
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
      service = ChatService(
        transport,
        convStore,
        msgStore,
        myCrypto,
        _localCrypto,
        null,
        prefs,
      );
      chat = ChatProvider(service, convStore, msgStore, transport);
      // Pin both peers' keys so the only failure left is the offline mode.
      for (final peer in [_peerUuid, _otherUuid]) {
        service.registerVerifiedPeerKey(peer, peerKeys['publicKey']!);
      }
    });

    test('a failure in one thread does not surface in another', () async {
      final convA = MessageStore.conversationId(_myUuid, _peerUuid);
      final convB = MessageStore.conversationId(_myUuid, _otherUuid);

      transport.mode = TransportMode.lan;
      await chat.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer A',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'seed',
        myPublicKeyPEM: null,
        peerPublicKeyPEM: null,
      );
      expect(chat.errorFor(convA), isNull);

      // Blocking the peer makes sends to thread A fail loudly while thread B
      // keeps working (the service-level block is the authority).
      service.attachBlockedPeers({_peerUuid});
      await chat.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer A',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'should fail',
        myPublicKeyPEM: null,
        peerPublicKeyPEM: null,
      );

      await chat.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _otherUuid,
        peerDisplayName: 'Peer B',
        peerShortId: 'PEERB2',
        type: MessageType.text,
        content: 'to the other thread',
        myPublicKeyPEM: null,
        peerPublicKeyPEM: null,
      );

      expect(chat.errorFor(convA), isNotNull,
          reason: 'the failed thread carries its own error');
      expect(chat.errorFor(convB), isNull,
          reason: 'the successful thread must stay clean');

      chat.clearError(convA);
      expect(chat.errorFor(convA), isNull);
      expect(chat.errorFor(convB), isNull);
    });
  });

  group('bottom-anchored scrolling (UI review #8)', () {
    late _ModeTransport transport;
    late ChatProvider chat;
    late MessageStore msgStore;
    late AuthProvider auth;
    late Conversation conversation;
    late PrefsStore prefs;
    late String convId;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = PrefsStore();
      await prefs.init();
      transport = _ModeTransport();
      final secure = SecureStore();
      final crypto = CryptoService();
      final authService = AuthService(
        secure,
        prefs,
        ProfileService(prefs, _localCrypto),
        crypto,
        KeyStore(secure, crypto),
        _localCrypto,
      );
      auth = AuthProvider(authService, transport);
      auth.updateUser(
        LocalUser(
          id: _myUuid,
          username: 'Me',
          gender: Gender.unspecified,
          interests: const [],
          publicKeyPEM: 'key',
          shortId: 'ME1234',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );
      final convStore = ConversationStore(prefs, _localCrypto);
      msgStore = MessageStore(prefs, _localCrypto);
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
      convId = MessageStore.conversationId(_myUuid, _peerUuid);
      conversation = Conversation(
        id: convId,
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        lastTransport: TransportMode.lan,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      // A long history so the list overflows the viewport.
      for (var i = 0; i < 40; i++) {
        await msgStore.addMessage(
          Message(
            id: 'seed-$i',
            conversationId: convId,
            senderId: i.isEven ? _myUuid : _peerUuid,
            type: MessageType.text,
            content: 'seed message $i',
            status: MessageStatus.sent,
            transport: TransportMode.lan,
            timestamp: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          ),
        );
      }
    });

    testWidgets('the newest message sits at the bottom without scroll jumps',
        (tester) async {
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

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(
        position.pixels,
        0,
        reason: 'a reverse list anchors index 0 (the newest) at the bottom',
      );

      // A new message sent offline appears in place, still bottom-anchored,
      // without any scroll jump.
      transport.mode = TransportMode.none;
      await chat.sendMessage(
        myUuid: _myUuid,
        myShortId: 'ME1234',
        myDisplayName: 'Me',
        peerUuid: _peerUuid,
        peerDisplayName: 'Peer',
        peerShortId: 'PEER12',
        type: MessageType.text,
        content: 'arrives at the bottom',
        myPublicKeyPEM: null,
        peerPublicKeyPEM: null,
      );
      await tester.pumpAndSettle();

      expect(position.pixels, 0);
      expect(find.text('arrives at the bottom'), findsOneWidget);
    });
  });

  group('recording UX (UI review #14)', () {
    testWidgets('shows a timer, cancel and stop while recording',
        (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageInputBar(
              canSendMedia: true,
              isRecording: true,
              onSendText: (_) async => true,
              onCancelRecording: () => cancelled = true,
              onPickImage: () {},
              onCapturePhoto: () {},
              onToggleRecord: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Recording 00:00'), findsOneWidget);

      // The timer ticks once per second.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.textContaining('Recording 00:02'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      expect(cancelled, isTrue, reason: 'cancel discards the recording');
      expect(find.byIcon(Icons.stop_circle), findsOneWidget,
          reason: 'stop sends the recording');
    });
  });

  group('fullscreen image viewer (UI review #15)', () {
    // A valid 1x1 PNG so Image.memory decodes without real IO.
    final Uint8List pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );

    testWidgets('shows the image zoomable', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: FullscreenImageView(
              file: File('unused'),
              crypto: null,
              loader: (file) async => Uint8List.fromList(pngBytes),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows an unavailable state for a broken file', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: FullscreenImageView(
              file: File('unused'),
              crypto: null,
              loader: (file) async => Uint8List(0),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Image unavailable'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
    });
  });
}
