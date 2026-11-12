import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/discovery_provider.dart';
import '../core/constants.dart';
import '../core/logging.dart';
import '../services/storage/prefs_store.dart';
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

  /// Whether the cold-start bootstrap already fired the biometric prompt
  /// (UI review #3): SignInScreen must not ask again right after it.
  bool _biometricAttempted = false;

  late final AuthProvider _auth;
  StreamSubscription? _announcementSub;

  @override
  void initState() {
    super.initState();
    // Attach listener after first frame so providers are in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _auth = context.read<AuthProvider>();
      _authInitialized = true;
      // Listener fires on every auth state change the guard inside
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

  // Called whenever AuthProvider notifies starts or tears down the session.
  void _handleAuthChanged() {
    if (!mounted) return;
    if (_auth.isSignedIn && _auth.user != null && !_transportsStarted) {
      // Load profile so ProfileProvider is populated for the main shell.
      context.read<ProfileProvider>().setUser(_auth.user!);
      _transportsStarted = true;
      _startTransports(_auth.user!.id);
    } else if (!_auth.isSignedIn && _transportsStarted) {
      // Signing out (or switching accounts) must reset everything the old
      // session accumulated otherwise the next account inherits its
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

      // One-time notice for local data that was quarantined during startup
      // because it could not be decrypted (audit M-1).
      final prefs = context.read<PrefsStore>();
      if (prefs.getBool(AhoyConstants.prefQuarantineNotice)) {
        await prefs.setBool(AhoyConstants.prefQuarantineNotice, value: false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Some local data could not be decrypted and was moved aside.',
              ),
            ),
          );
        }
      }

      if (_auth.isSignedIn && _auth.user == null) {
        // Attempt biometric fast-path; falls through to password screen if
        // denied. SignInScreen suppresses its own automatic prompt so the
        // user is never asked twice in a row (UI review #3).
        _biometricAttempted = true;
        await _auth.signInWithBiometric();
      }
      // _maybeStartTransports() will have fired via the listener if signIn succeeded.
    } catch (e) {
      ahoyLog('[RootScreen] bootstrap error', e);
    } finally {
      if (mounted) setState(() => _checkingSession = false);
    }
  }

  /// Request all runtime permissions the transports need, with a rationale
  /// before the first system prompt, and surface any denials on the Discover
  /// screen so a missing permission is never mistaken for "no peers nearby"
  /// (UI review #6).
  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;
    const needed = [
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
    ];

    // Explain why before the first prompt: Android ties nearby-device
    // discovery to location permissions, which is not self-evident for a
    // messenger that never tracks location.
    final prefs = context.read<PrefsStore>();
    final statuses = {for (final p in needed) p: await p.status};
    final needsRationale = statuses.values.any(
      (s) => s == PermissionStatus.denied || s == PermissionStatus.restricted,
    );
    if (needsRationale &&
        !prefs.getBool(AhoyConstants.prefPermissionRationaleSeen)) {
      await prefs.setBool(AhoyConstants.prefPermissionRationaleSeen, value: true);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Finding nearby peers'),
          content: const Text(
            'Ahoy talks directly to nearby devices over Bluetooth and Wi-Fi — '
            'there is no server. Android requires the location and '
            'nearby-devices permissions for this kind of discovery, even '
            'though Ahoy never learns or shares your location. Nothing leaves '
            'your immediate surroundings.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (!mounted) return;
    }

    final results = await [
      Permission.locationWhenInUse,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
    ].request();

    bool granted(Permission p) =>
        results[p] == PermissionStatus.granted ||
        results[p] == PermissionStatus.limited;
    final problems = <String>[];
    if (!granted(Permission.bluetoothScan)) {
      problems.add(
        'Bluetooth scanning is blocked — nearby discovery over BLE cannot run.',
      );
    }
    if (!granted(Permission.bluetoothConnect)) {
      problems.add(
        'Bluetooth connect is blocked — BLE chats cannot open.',
      );
    }
    if (!granted(Permission.nearbyWifiDevices)) {
      problems.add(
        'Nearby devices permission is blocked — WiFi Direct cannot run.',
      );
    }
    if (!granted(Permission.locationWhenInUse)) {
      problems.add(
        'Location permission is blocked — Android requires it for nearby '
        'discovery on this Android version.',
      );
    }
    if (!mounted) return;
    context.read<DiscoveryProvider>().setPermissionProblems(problems);
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
        offGrid: discovery.offGrid,
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

      await _maybeShowOnboarding();
    } catch (e) {
      ahoyLog('[RootScreen] startTransports error', e);
    }
  }

  /// One-time explanation of the offline model (UI review #7): the app only
  /// works nearby and while it is in the foreground — there is no server,
  /// no push, and no delivery to a peer who has walked away.
  Future<void> _maybeShowOnboarding() async {
    final prefs = context.read<PrefsStore>();
    if (prefs.getBool(AhoyConstants.prefOnboardingSeen)) return;
    await prefs.setBool(AhoyConstants.prefOnboardingSeen, value: true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('How Ahoy works'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '• No servers. Messages travel directly between nearby '
                'devices over Bluetooth, your Wi-Fi network, or WiFi Direct.',
              ),
              SizedBox(height: 8),
              Text(
                '• Nearby only. You can only reach people within radio range. '
                'If a peer walks away, your message waits and is delivered '
                'when they appear again.',
              ),
              SizedBox(height: 8),
              Text(
                '• Foreground only. Discovery and delivery run while the app '
                'is open — there is no background delivery or notification.',
              ),
              SizedBox(height: 8),
              Text(
                '• End-to-end encrypted. Compare the safety number on a '
                'peer’s profile to verify the connection out of band.',
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
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
        // onSignedUp is a no-op here the AuthProvider listener in initState
        // handles transport start as soon as signUp() sets state to signedIn.
        onSignedUp: () async {},
      );
    }

    return SignInScreen(
      onSignUp: () => setState(() => _showSignUp = true),
      // Same: listener handles everything; callback kept for interface consistency.
      onSignedIn: () async {},
      autoPromptBiometric: !_biometricAttempted,
    );
  }
}
