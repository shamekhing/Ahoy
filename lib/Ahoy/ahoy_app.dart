import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/storage/secure_store.dart';
import 'services/storage/prefs_store.dart';
import 'services/crypto/crypto_service.dart';
import 'services/crypto/key_store.dart';
import 'services/crypto/local_data_crypto.dart';
import 'services/auth/auth_service.dart';
import 'services/profile/profile_service.dart';
import 'services/transport_manager.dart';
import 'services/discovery/discovery_service.dart';
import 'services/chat/conversation_store.dart';
import 'services/chat/message_store.dart';
import 'services/chat/chat_service.dart';
import 'services/maintenance/local_data_migrator.dart';
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

  // Services created once, injected via Provider. Nullable so a failed
  // startup commits nothing and a retry starts clean (UI review #29).
  SecureStore? _secureStore;
  PrefsStore? _prefsStore;
  CryptoService? _cryptoService;
  LocalDataCrypto? _localDataCrypto;
  AuthService? _authService;
  ProfileService? _profileService;
  TransportManager? _transportManager;
  DiscoveryService? _discoveryService;
  ConversationStore? _convStore;
  MessageStore? _msgStore;
  ChatService? _chatService;
  MediaService? _mediaService;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Build everything into locals first: if any step throws, no
    // half-initialized service is committed to state and a retry starts
    // from a clean slate (UI review #29).
    TransportManager? pendingTransport;
    MediaService? pendingMedia;
    try {
      final secureStore = SecureStore();
      final prefsStore = PrefsStore();
      await prefsStore.init();

      final cryptoService = CryptoService();
      final keyStore = KeyStore(secureStore, cryptoService);
      final localDataCrypto = LocalDataCrypto(secureStore);
      // Rewrites Keychain items with the device-bound accessibility option
      // before the at-rest key is read (audit M-1).
      await secureStore.migrateAccessibility(prefsStore);
      await localDataCrypto.init();

      final profileService = ProfileService(prefsStore, localDataCrypto);

      pendingTransport = TransportManager(crypto: cryptoService);
      final discoveryService = DiscoveryService();

      final convStore = ConversationStore(prefsStore, localDataCrypto);
      final msgStore = MessageStore(prefsStore, localDataCrypto);
      await LocalDataMigrator(
        profileService,
        convStore,
        msgStore,
        localDataCrypto,
        null,
        prefsStore,
      ).migrate();

      final authService = AuthService(
        secureStore,
        prefsStore,
        profileService,
        cryptoService,
        keyStore,
        localDataCrypto,
      );
      // Detects a Keychain-survives-reinstall stale identity before the
      // migrator touches anything (audit M-1).
      await authService.reconcileReinstall();
      final chatService = ChatService(
        pendingTransport,
        convStore,
        msgStore,
        cryptoService,
        localDataCrypto,
        null,
        prefsStore,
      );

      pendingMedia = MediaService(localDataCrypto);

      setState(() {
        _secureStore = secureStore;
        _prefsStore = prefsStore;
        _cryptoService = cryptoService;
        _localDataCrypto = localDataCrypto;
        _profileService = profileService;
        _transportManager = pendingTransport;
        _discoveryService = discoveryService;
        _convStore = convStore;
        _msgStore = msgStore;
        _authService = authService;
        _chatService = chatService;
        _mediaService = pendingMedia;
        _ready = true;
      });
    } catch (e) {
      // Roll back partially built services so a retry does not leak
      // transports or recorders.
      pendingTransport?.dispose();
      pendingMedia?.dispose();
      setState(() => _initError = e.toString());
    }
  }

  /// Retry startup after a failure (UI review #29). Init works on locals,
  /// so state is untouched unless everything succeeded.
  Future<void> _retryInit() async {
    setState(() {
      _initError = null;
      _ready = false;
    });
    await _init();
  }

  @override
  void dispose() {
    _transportManager?.dispose();
    _mediaService?.dispose();
    super.dispose();
  }

  /// Best-effort wipe of local data (prefs + secure storage) followed by a
  /// fresh retry — the last-resort path when ordinary startup cannot
  /// recover (UI review #29). [dialogContext] must live under the error
  /// screen's Navigator so the confirm dialog can be shown.
  Future<void> _resetAndRetry(BuildContext dialogContext) async {
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (_) => AlertDialog(
        title: const Text('Erase local data?'),
        content: const Text(
          'Your identity, conversations and keys on this device are erased. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final prefs = PrefsStore();
      await prefs.init();
      await prefs.clearAll();
    } catch (_) {/* best effort */}
    try {
      await SecureStore().clearAll();
    } catch (_) {/* best effort */}
    await _retryInit();
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      // Startup failure is recoverable now (UI review #29): explain what
      // happened without a raw dump up front, offer retry, and keep the
      // exception tucked away in a Details expander.
      return MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (errorContext) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 56,
                      color: Theme.of(errorContext).colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    const Text('Ahoy could not start'),
                    const SizedBox(height: 4),
                    const Text(
                      'Your data is intact. Try again, or erase local data if '
                      'the problem persists.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      onPressed: _retryInit,
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => _resetAndRetry(errorContext),
                      child: Text(
                        'Erase local data and retry',
                        style: TextStyle(
                          color: Theme.of(errorContext).colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ExpansionTile(
                      title: const Text(
                        'Details',
                        style: TextStyle(fontSize: 13),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'Startup error:\n$_initError',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(errorContext).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
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

    // Local promotion: _ready guarantees the services were committed.
    final secureStore = _secureStore!;
    final prefsStore = _prefsStore!;
    final cryptoService = _cryptoService!;
    final localDataCrypto = _localDataCrypto!;
    final transportManager = _transportManager!;
    final profileService = _profileService!;
    final discoveryService = _discoveryService!;
    final convStore = _convStore!;
    final msgStore = _msgStore!;
    final authService = _authService!;
    final chatService = _chatService!;
    final mediaService = _mediaService!;

    return MultiProvider(
      providers: [
        // Plain services accessible via context.read<T>(). The locals promote
        // the nullable fields: _ready guarantees every service is set.
        Provider<SecureStore>.value(value: secureStore),
        Provider<PrefsStore>.value(value: prefsStore),
        Provider<CryptoService>.value(value: cryptoService),
        Provider<LocalDataCrypto>.value(value: localDataCrypto),
        Provider<TransportManager>.value(value: transportManager),
        Provider<ProfileService>.value(value: profileService),
        Provider<MediaService>.value(value: mediaService),

        // State providers notify listeners on change
        ChangeNotifierProvider(
          create: (_) => AuthProvider(authService, transportManager),
        ),
        ChangeNotifierProvider(create: (_) => ProfileProvider(profileService)),
        ChangeNotifierProvider(
          create: (_) => TransportProvider(transportManager),
        ),
        ChangeNotifierProvider(
          create: (_) => DiscoveryProvider(
            discoveryService,
            transportManager,
            prefsStore,
            cryptoService,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(
            chatService,
            convStore,
            msgStore,
            transportManager,
          ),
        ),
      ],
      child: MaterialApp(
        title: 'Ahoy',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
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
