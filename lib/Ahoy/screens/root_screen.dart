import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/discovery_provider.dart';
import '../core/logging.dart';
import '../services/transport_manager.dart';
import 'auth/sign_in_screen.dart';
import 'auth/sign_up_screen.dart';
import 'main_shell.dart';

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  bool _checkingSession = true;
  bool _showSignUp = false;
  bool _transportsStarted = false;
  bool _authInitialized = false;

  late final AuthProvider _auth;
  StreamSubscription? _announcementSub;

  @override
  void initState() {
    super.initState();
    // Attach listener after first frame so providers are in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _auth = context.read<AuthProvider>();
      _authInitialized = true;
      // Listener fires on every auth state change — the guard inside
      // _maybeStartTransports() ensures it only runs once per session.
      _auth.addListener(_handleAuthChanged);
      _bootstrap();
    });
  }

  @override
  void dispose() {
    if (_authInitialized) _auth.removeListener(_handleAuthChanged);
    _announcementSub?.cancel();
    super.dispose();
  }

  // Called whenever AuthProvider notifies — starts or tears down the session.
  void _handleAuthChanged() {
    if (!mounted) return;
    if (_auth.isSignedIn && _auth.user != null && !_transportsStarted) {
      // Load profile so ProfileProvider is populated for the main shell.
      context.read<ProfileProvider>().setUser(_auth.user!);
      _transportsStarted = true;
      _startTransports(_auth.user!.id);
    } else if (!_auth.isSignedIn && _transportsStarted) {
      // Signing out (or switching accounts) must reset everything the old
      // session accumulated — otherwise the next account inherits its
      // conversations, discovery state, and inbound routing (audit #3).
      _teardownSession();
    }
  }

  void _teardownSession() {
    _announcementSub?.cancel();
    _announcementSub = null;
    _transportsStarted = false;
    context.read<ChatProvider>().reset();
    context.read<DiscoveryProvider>().reset();
    context.read<ProfileProvider>().clear();
  }

  // Cold-start: check for an existing session stored from a previous run.
  Future<void> _bootstrap() async {
    try {
      await _auth.checkSession();
      if (!mounted) return;

      if (_auth.isSignedIn && _auth.user == null) {
        // Attempt biometric fast-path; falls through to password screen if denied.
        await _auth.signInWithBiometric();
      }
      // _maybeStartTransports() will have fired via the listener if signIn succeeded.
    } catch (e) {
      ahoyLog('[RootScreen] bootstrap error', e);
    } finally {
      if (mounted) setState(() => _checkingSession = false);
    }
  }

  /// Request all runtime permissions the transports need.
  /// Silently continues if any are denied — each transport handles
  /// its own failure gracefully.
  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;
    await [
      // Location — required for BLE scan on Android < 12 and
      // for WiFi Direct on Android < 13.
      Permission.locationWhenInUse,
      // Android 12+ granular Bluetooth permissions.
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      // Android 13+ scoped WiFi permission for WiFi Direct / P2P.
      Permission.nearbyWifiDevices,
    ].request();
  }

  Future<void> _startTransports(String myUuid) async {
    if (!mounted) return;
    try {
      await _requestPermissions();
      if (!mounted) return;

      final user = _auth.user!;
      final transport = context.read<TransportManager>();
      final discovery = context.read<DiscoveryProvider>();

      await transport.start(
        uuid: user.id,
        shortId: user.shortId,
        displayName: user.username,
        statusMessage: user.statusMessage,
        publicKeyPEM: user.publicKeyPEM,
        bleEnabled: discovery.bleEnabled,
        lanEnabled: discovery.lanEnabled,
        wifiDirectEnabled: discovery.wifiDirectEnabled,
      );

      if (!mounted) return;

      _announcementSub = transport.announcementStream.listen((a) {
        if (mounted) {
          context.read<DiscoveryProvider>().onAnnouncement(a);
          // A returning peer may have undelivered messages queued (audit M-3).
          context.read<ChatProvider>().maybeRetryFor(a.uuid);
        }
      });

      if (!mounted) return;

      final chatProvider = context.read<ChatProvider>();
      // Verified announcement keys pin first-contact conversations (audit #7).
      discovery.onVerifiedKey = chatProvider.registerVerifiedPeerKey;

      chatProvider.init(
        myUuid: user.id,
        myShortId: user.shortId,
        myDisplayName: user.username,
        myPublicKeyPEM: user.publicKeyPEM,
        receiveOff: () => context.read<DiscoveryProvider>().receiveOff,
        blockedUuids: discovery.blockedUuids,
      );
    } catch (e) {
      ahoyLog('[RootScreen] startTransports error', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final auth = context.watch<AuthProvider>();

    if (auth.isSignedIn && auth.user != null) {
      return const MainShell();
    }

    if (_showSignUp) {
      return SignUpScreen(
        onSignIn: () => setState(() => _showSignUp = false),
        // onSignedUp is a no-op here — the AuthProvider listener in initState
        // handles transport start as soon as signUp() sets state to signedIn.
        onSignedUp: () async {},
      );
    }

    return SignInScreen(
      onSignUp: () => setState(() => _showSignUp = true),
      // Same: listener handles everything; callback kept for interface consistency.
      onSignedIn: () async {},
    );
  }
}
