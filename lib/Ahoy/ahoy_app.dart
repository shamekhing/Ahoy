import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/storage/secure_store.dart';
import 'services/storage/prefs_store.dart';
import 'services/crypto/crypto_service.dart';
import 'services/crypto/key_store.dart';
import 'services/auth/auth_service.dart';
import 'services/profile/profile_service.dart';
import 'services/transport_manager.dart';
import 'services/discovery/discovery_service.dart';
import 'services/chat/conversation_store.dart';
import 'services/chat/message_store.dart';
import 'services/chat/chat_service.dart';
import 'services/media/media_service.dart';
import 'providers/auth_provider.dart';
import 'providers/profile_provider.dart';
import 'providers/transport_provider.dart';
import 'providers/discovery_provider.dart';
import 'providers/chat_provider.dart';
import 'screens/root_screen.dart';

class AhoyApp extends StatefulWidget {
  const AhoyApp({super.key});

  @override
  State<AhoyApp> createState() => _AhoyAppState();
}

class _AhoyAppState extends State<AhoyApp> {
  bool _ready = false;
  String? _initError;

  // Services — created once, injected via Provider
  late final SecureStore _secureStore;
  late final PrefsStore _prefsStore;
  late final CryptoService _cryptoService;
  late final KeyStore _keyStore;
  late final AuthService _authService;
  late final ProfileService _profileService;
  late final TransportManager _transportManager;
  late final DiscoveryService _discoveryService;
  late final ConversationStore _convStore;
  late final MessageStore _msgStore;
  late final ChatService _chatService;
  late final MediaService _mediaService;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _secureStore = SecureStore();
      _prefsStore = PrefsStore();
      await _prefsStore.init();

      _cryptoService = CryptoService();
      _keyStore = KeyStore(_secureStore, _cryptoService);

      _authService = AuthService(_secureStore, _prefsStore, _cryptoService, _keyStore);
      _profileService = ProfileService(_prefsStore);

      _transportManager = TransportManager();
      _discoveryService = DiscoveryService();

      _convStore = ConversationStore(_prefsStore);
      _msgStore = MessageStore(_prefsStore);
      _chatService = ChatService(_transportManager, _convStore, _msgStore, _cryptoService);

      _mediaService = MediaService();

      setState(() => _ready = true);
    } catch (e) {
      setState(() => _initError = e.toString());
    }
  }

  @override
  void dispose() {
    _transportManager.dispose();
    _mediaService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Startup error:\n$_initError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red)),
            ),
          ),
        ),
      );
    }

    if (!_ready) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MultiProvider(
      providers: [
        // Plain services — accessible via context.read<T>()
        Provider<SecureStore>.value(value: _secureStore),
        Provider<PrefsStore>.value(value: _prefsStore),
        Provider<CryptoService>.value(value: _cryptoService),
        Provider<TransportManager>.value(value: _transportManager),
        Provider<ProfileService>.value(value: _profileService),
        Provider<MediaService>.value(value: _mediaService),

        // State providers — notify listeners on change
        ChangeNotifierProvider(
          create: (_) => AuthProvider(_authService, _transportManager),
        ),
        ChangeNotifierProvider(
          create: (_) => ProfileProvider(_profileService),
        ),
        ChangeNotifierProvider(
          create: (_) => TransportProvider(_transportManager),
        ),
        ChangeNotifierProvider(
          create: (_) => DiscoveryProvider(_discoveryService, _transportManager, _prefsStore),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(_chatService, _convStore, _msgStore, _transportManager),
        ),
      ],
      child: MaterialApp(
        title: 'Ahoy',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const RootScreen(),
      ),
    );
  }
}
