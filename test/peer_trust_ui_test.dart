import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/nearby_peer.dart';
import 'package:ahoy/Ahoy/providers/auth_provider.dart';
import 'package:ahoy/Ahoy/providers/chat_provider.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/screens/profile/peer_profile_screen.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/chat/chat_service.dart';
import 'package:ahoy/Ahoy/services/chat/conversation_store.dart';
import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:ahoy/Ahoy/services/crypto/peer_trust_store.dart';
import 'package:ahoy/Ahoy/widgets/discover/peer_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _peerUuid = '22222222-2222-4222-8222-222222222222';

NearbyPeer _peer() => NearbyPeer(
      uuid: _peerUuid,
      shortId: 'PEER12',
      displayName: 'Peer',
      transport: TransportMode.lan,
      lastSeen: DateTime.now(),
      publicKeyPEM: 'KEY_A',
    );

class _SilentTransport extends TransportManager {
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
    return true;
  }
}

Future<ChatProvider> _chatProvider() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  final convStore = ConversationStore(prefs);
  final msgStore = MessageStore(prefs);
  final transport = _SilentTransport();
  final service = ChatService(
    transport,
    convStore,
    msgStore,
    CryptoService(),
  );
  return ChatProvider(service, convStore, msgStore, transport);
}

Future<AuthProvider> _authProvider() async {
  FlutterSecureStorage.setMockInitialValues({});
  final secure = SecureStore();
  final prefs = PrefsStore();
  await prefs.init();
  final crypto = CryptoService();
  final localDataCrypto = LocalDataCrypto(secure);
  await localDataCrypto.init();
  final authService = AuthService(
    secure,
    prefs,
    ProfileService(prefs, localDataCrypto),
    crypto,
    KeyStore(secure, crypto),
    localDataCrypto,
  );
  return AuthProvider(authService, TransportManager());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'profile shows the unverified chip and no banner without a conflict',
    (tester) async {
      final chat = await _chatProvider();
      final auth = await _authProvider();
      final discovery = DiscoveryProvider(
        DiscoveryService(),
        TransportManager(),
        await _prefs(),
        CryptoService(),
      );
      chat.registerVerifiedPeerKey(_peerUuid, 'KEY_A');
      try {
        await tester.pumpWidget(_wrap(chat, auth, discovery));
        await tester.pumpAndSettle();

        expect(find.text('Unverified'), findsOneWidget);
        expect(find.text('Identity changed'), findsNothing);
      } finally {
        // testWidgets teardowns run after the timer invariant check, so the
        // periodic discovery cleanup timer must stop inside the body.
        chat.dispose();
        discovery.dispose();
      }
    },
  );

  testWidgets(
    'a conflicting announced key raises the banner and the safety-number '
    'action promotes trust',
    (tester) async {
      final chat = await _chatProvider();
      final auth = await _authProvider();
      final discovery = DiscoveryProvider(
        DiscoveryService(),
        TransportManager(),
        await _prefs(),
        CryptoService(),
      );
      expect(chat.registerVerifiedPeerKey(_peerUuid, 'KEY_A'), isTrue);
      expect(chat.registerVerifiedPeerKey(_peerUuid, 'KEY_B'), isFalse);
      try {
        await tester.pumpWidget(_wrap(chat, auth, discovery));
        await tester.pumpAndSettle();

        expect(find.text('Identity changed'), findsOneWidget);

        // Rejecting the announced change clears the warning and keeps the
        // known key (sixth review, finding 4).
        await tester.tap(find.text('Keep current key'));
        await tester.pumpAndSettle();

        expect(find.text('Identity changed'), findsNothing);
        expect(chat.peerTrust(_peerUuid)!.pendingKey, isNull);
        expect(chat.peerTrust(_peerUuid)!.key, 'KEY_A');

        // A new announced change raises the banner again; the safety-number
        // action promotes the peer to verified.
        chat.registerVerifiedPeerKey(_peerUuid, 'KEY_C');
        await tester.pumpAndSettle();
        expect(find.text('Identity changed'), findsOneWidget);

        await tester.tap(find.text('Mark as verified'));
        await tester.pumpAndSettle();

        expect(find.text('Identity changed'), findsNothing);
        expect(find.text('Verified by safety number'), findsOneWidget);
        expect(
          chat.peerTrust(_peerUuid)!.state,
          PeerTrustState.verifiedBySafetyNumber,
        );
      } finally {
        chat.dispose();
        discovery.dispose();
      }
    },
  );

  testWidgets('peer cards carry the unverified marker', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerCard(
            peer: _peer(),
            trustState: PeerTrustState.unverified,
            onConnect: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.help_outline), findsOneWidget);
  });
}

Future<PrefsStore> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = PrefsStore();
  await prefs.init();
  return prefs;
}

Widget _wrap(ChatProvider chat, AuthProvider auth, DiscoveryProvider discovery) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<DiscoveryProvider>.value(value: discovery),
      ChangeNotifierProvider<ChatProvider>.value(value: chat),
    ],
    child: MaterialApp(
      home: Scaffold(body: PeerProfileScreen(peer: _peer())),
    ),
  );
}

