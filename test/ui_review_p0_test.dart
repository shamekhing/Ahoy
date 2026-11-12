import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/providers/auth_provider.dart';
import 'package:ahoy/Ahoy/providers/discovery_provider.dart';
import 'package:ahoy/Ahoy/providers/profile_provider.dart';
import 'package:ahoy/Ahoy/screens/auth/sign_in_screen.dart';
import 'package:ahoy/Ahoy/screens/settings/settings_screen.dart';
import 'package:ahoy/Ahoy/services/auth/auth_service.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/key_store.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/services/discovery/discovery_service.dart';
import 'package:ahoy/Ahoy/services/profile/profile_service.dart';
import 'package:ahoy/Ahoy/services/storage/prefs_store.dart';
import 'package:ahoy/Ahoy/services/storage/secure_store.dart';
import 'package:ahoy/Ahoy/services/transport/ble_transport.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:ahoy/Ahoy/services/transport/wifi_direct_transport.dart';
import 'package:ahoy/Ahoy/services/transport_manager.dart';
import 'package:ahoy/Ahoy/widgets/chat/message_input_bar.dart';
import 'package:ahoy/Ahoy/widgets/chat/reply_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ninth-review follow-up: P0 findings from the external UI/UX review,
/// each verified against the source before fixing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reply preview labels (UI review #1)', () {
    Message message(MessageType type, String content) => Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'peer',
      type: type,
      content: content,
      status: MessageStatus.sent,
      transport: TransportMode.lan,
      timestamp: DateTime.utc(2026, 1, 1),
    );

    test('media replies quote a label instead of the local file path', () {
      const path = '/data/user/0/com.ahoy.app/files/ahoy_media_x.jpg.ahoyenc';
      expect(ReplyPreview.labelFor(message(MessageType.image, path)), '[Photo]');
      expect(
        ReplyPreview.labelFor(message(MessageType.voice, path)),
        '[Voice message]',
      );
    });

    test('text replies quote the content, truncated to 80 characters', () {
      expect(ReplyPreview.labelFor(message(MessageType.text, 'hello')), 'hello');
      final long = 'a' * 100;
      expect(
        ReplyPreview.labelFor(message(MessageType.text, long)),
        '${'a' * 80}…',
      );
    });

    test('inbound previews that contain a path are sanitized', () {
      const path = '/data/user/0/com.ahoy.app/files/ahoy_media_y.aac.ahoyenc';
      expect(ReplyPreview.sanitize(path), '[Media]');
      expect(
        ReplyPreview.sanitize('just a normal quote'),
        'just a normal quote',
      );
    });

    group('message input bar (UI review #2)', () {
      testWidgets('keeps the text when the send fails', (tester) async {
        var succeed = false;
        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MessageInputBar(
                canSendMedia: true,
                isRecording: false,
                onSendText: (text) async {
                  calls++;
                  return succeed;
                },
                onCancelRecording: () {},
                onPickImage: () {},
                onCapturePhoto: () {},
                onToggleRecord: () {},
              ),
            ),
          ),
        );

        await tester.enterText(find.byType(TextField), 'do not lose me');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();

        expect(calls, 1);
        expect(
          find.text('do not lose me'),
          findsOneWidget,
          reason: 'a failed send must not discard the text',
        );

        succeed = true;
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        expect(calls, 2);
        expect(find.text('do not lose me'), findsNothing,
            reason: 'the field clears only after success');
      });
    });

    group('single biometric prompt (UI review #3)', () {
      late SecureStore secure;
      late PrefsStore prefs;
      late LocalDataCrypto localCrypto;
      late _RecordingAuth auth;

      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        secure = SecureStore();
        prefs = PrefsStore();
        await prefs.init();
        localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));
        final crypto = CryptoService();
        final authService = AuthService(
          secure,
          prefs,
          ProfileService(prefs, localCrypto),
          crypto,
          KeyStore(secure, crypto),
          localCrypto,
        );
        auth = _RecordingAuth(authService, TransportManager());
      });

      testWidgets('suppresses the automatic prompt after bootstrap tried',
          (tester) async {
        await tester.pumpWidget(
          ChangeNotifierProvider<AuthProvider>.value(
            value: auth,
            child: MaterialApp(
              home: SignInScreen(
                onSignUp: () {},
                onSignedIn: () async {},
                autoPromptBiometric: false,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          auth.biometricAttempts,
          0,
          reason: 'bootstrap already prompted once; no second prompt',
        );
        // The manual button remains for an explicit retry.
        expect(find.text('Use Biometric'), findsOneWidget);
      });

      testWidgets('auto-prompts when bootstrap did not try', (tester) async {
        await tester.pumpWidget(
          ChangeNotifierProvider<AuthProvider>.value(
            value: auth,
            child: MaterialApp(
              home: SignInScreen(
                onSignUp: () {},
                onSignedIn: () async {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(auth.biometricAttempts, 1);
      });
    });

    group('pull-to-refresh does not tear down live transports (UI review #4)',
        () {
      test('restartScanning restarts scanning but never stops advertising',
          () async {
        final wd = _SpyWiFiDirect();
        final lan = _SpyLan();
        final ble = _SpyBle();
        final tm = TransportManager(wifiDirect: wd, lan: lan, ble: ble);
        addTearDown(tm.dispose);

        await tm.start(
          uuid: '11111111-1111-4111-8111-111111111111',
          shortId: 'ME1234',
          displayName: 'Me',
          bleEnabled: true,
          lanEnabled: true,
          wifiDirectEnabled: true,
        );
        // start() itself runs one scan-start per transport; measure deltas.
        final wdStops = wd.stopScanningCalls;
        final wdStarts = wd.startScanningCalls;
        final lanStops = lan.stopScanningCalls;
        final lanStarts = lan.startScanningCalls;
        final bleStops = ble.stopScanningCalls;
        final bleStarts = ble.startScanningCalls;
        final wdStopsAdvertising = wd.stopAdvertisingCalls;
        final lanAdvertises = lan.startAdvertisingCalls;
        final bleAdvertises = ble.startAdvertisingCalls;

        await tm.restartScanning();

        // Scanning restarted on all three transports...
        expect(wd.stopScanningCalls, wdStops + 1);
        expect(wd.startScanningCalls, wdStarts + 1);
        expect(lan.stopScanningCalls, lanStops + 1);
        expect(lan.startScanningCalls, lanStarts + 1);
        expect(ble.stopScanningCalls, bleStops + 1);
        expect(ble.startScanningCalls, bleStarts + 1);
        // ...and nothing stopped advertising: the WiFi Direct group survives.
        expect(wd.stopAdvertisingCalls, wdStopsAdvertising,
            reason: 'stopping advertising removes the WiFi Direct group');
        // The identity is re-announced on the connectionless transports.
        expect(lan.startAdvertisingCalls, lanAdvertises + 1);
        expect(ble.startAdvertisingCalls, bleAdvertises + 1);
      });

      test('the settings toggle still tears the group down on purpose',
          () async {
        final wd = _SpyWiFiDirect();
        final tm = TransportManager(wifiDirect: wd);
        addTearDown(tm.dispose);

        await tm.setWifiDirectEnabled(false);

        expect(wd.stopAdvertisingCalls, 1,
            reason: 'an explicit user toggle removes the group');
      });
    });

    group('lock instead of mislabeled erase (UI review #5)', () {
      late SecureStore secure;
      late PrefsStore prefs;
      late LocalDataCrypto localCrypto;
      late _SpyTransport transport;

      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        SharedPreferences.setMockInitialValues({});
        secure = SecureStore();
        prefs = PrefsStore();
        await prefs.init();
        localCrypto = LocalDataCrypto.withKeyForTesting(Uint8List(32));
        transport = _SpyTransport();
      });

      AuthService authService() {
        final crypto = CryptoService();
        return AuthService(
          secure,
          prefs,
          ProfileService(prefs, localCrypto),
          crypto,
          KeyStore(secure, crypto),
          localCrypto,
        );
      }

      test('lock stops transports and keeps the account; unlock restores it',
          () async {
        final provider = AuthProvider(authService(), transport);
        await provider.signUp(
          username: 'Locky',
          password: 'lock pass 123',
          gender: Gender.unspecified,
        );
        expect(provider.isSignedIn, isTrue);

        await provider.lock();

        expect(provider.isSignedIn, isFalse, reason: 'locked');
        expect(provider.user, isNull);
        expect(
          transport.stopAllCalls,
          1,
          reason: 'a locked device stops advertising and receiving',
        );

        // Unlocking is the normal sign-in flow and must restore the session
        // without any data loss.
        final ok = await provider.signIn(password: 'lock pass 123');
        expect(ok, isTrue);
        expect(provider.user!.username, 'Locky');
      });

      testWidgets('the settings dialog states the erasure is irreversible',
          (tester) async {
        final provider = AuthProvider(authService(), transport);
        final discovery = DiscoveryProvider(
          DiscoveryService(),
          transport,
          prefs,
          CryptoService(),
        );
        // The 10-second cleanup timer must not outlive the test body (widget
        // tests run in fake async and forbid pending timers), so the provider
        // is disposed at the end of the body instead of in a teardown.

        final profile = ProfileProvider(ProfileService(prefs, localCrypto));

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<AuthProvider>.value(value: provider),
              ChangeNotifierProvider<DiscoveryProvider>.value(value: discovery),
              ChangeNotifierProvider<ProfileProvider>.value(value: profile),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );

        // A non-destructive Lock is available next to the destructive action
        // (scroll: the settings list is lazy).
        await tester.dragUntilVisible(
          find.text('Lock'),
          find.byType(ListView).first,
          const Offset(0, -120),
        );
        expect(find.text('Lock'), findsOneWidget);

        await tester.dragUntilVisible(
          find.text('Sign Out & Erase Data'),
          find.byType(ListView).first,
          const Offset(0, -120),
        );
        await tester.pump();
        await tester.tap(find.text('Sign Out & Erase Data'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('cannot be undone'),
          findsOneWidget,
          reason: 'the dialog must carry the irreversible-erasure warning',
        );

        await tester.tap(find.text('Erase & Sign Out'));
        await tester.pumpAndSettle();
        expect(provider.isSignedIn, isFalse);
        discovery.dispose();
      });
    });
  });
}

class _RecordingAuth extends AuthProvider {
  int biometricAttempts = 0;
  _RecordingAuth(super.authService, super.transport);

  @override
  Future<bool> get isBiometricAvailable async => true;

  @override
  Future<bool> get isBiometricEnabled async => true;

  @override
  Future<bool> signInWithBiometric() async {
    biometricAttempts++;
    return false;
  }
}

class _SpyWiFiDirect extends WiFiDirectTransport {
  int stopScanningCalls = 0;
  int startScanningCalls = 0;
  int stopAdvertisingCalls = 0;

  @override
  Future<void> stopScanning() async {
    stopScanningCalls++;
    await super.stopScanning();
  }

  @override
  Future<void> startScanning() async {
    startScanningCalls++;
    await super.startScanning();
  }

  @override
  Future<void> stopAdvertising() async {
    stopAdvertisingCalls++;
    await super.stopAdvertising();
  }
}

class _SpyLan extends LanTransport {
  int stopScanningCalls = 0;
  int startScanningCalls = 0;
  int startAdvertisingCalls = 0;

  _SpyLan() : super(discoveryPort: 0, messagingPort: 0);

  @override
  Future<void> stopScanning() async {
    stopScanningCalls++;
    await super.stopScanning();
  }

  @override
  Future<void> startScanning() async {
    startScanningCalls++;
    await super.startScanning();
  }

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
    String? announcementSignature,
  }) async {
    startAdvertisingCalls++;
    await super.startAdvertising(
      uuid: uuid,
      shortId: shortId,
      displayName: displayName,
      statusMessage: statusMessage,
      publicKeyPEM: publicKeyPEM,
      announcementSignature: announcementSignature,
    );
  }
}

class _SpyBle extends BleTransport {
  int stopScanningCalls = 0;
  int startScanningCalls = 0;
  int startAdvertisingCalls = 0;

  @override
  Future<void> stopScanning() async {
    stopScanningCalls++;
    await super.stopScanning();
  }

  @override
  Future<void> startScanning() async {
    startScanningCalls++;
    await super.startScanning();
  }

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
    String? announcementSignature,
  }) async {
    startAdvertisingCalls++;
    await super.startAdvertising(
      uuid: uuid,
      shortId: shortId,
      displayName: displayName,
      statusMessage: statusMessage,
      publicKeyPEM: publicKeyPEM,
      announcementSignature: announcementSignature,
    );
  }
}

class _SpyTransport extends TransportManager {
  int stopAllCalls = 0;

  @override
  Future<void> stopAll() async {
    stopAllCalls++;
    await super.stopAll();
  }
}
