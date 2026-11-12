import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Manifest policy assertions for the narrowed permission set (audit M-7).
void main() {
  late String manifest;

  setUpAll(() {
    manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  });

  test('media permissions are not requested', () {
    expect(manifest.contains('android.permission.READ_MEDIA_IMAGES'), isFalse);
    expect(manifest.contains('android.permission.READ_MEDIA_AUDIO'), isFalse);
    expect(
      manifest.contains('android.permission.READ_EXTERNAL_STORAGE'),
      isFalse,
    );
  });

  test('BLUETOOTH_SCAN is marked neverForLocation', () {
    final scanEntry = RegExp(
      r'<uses-permission[^>]*android\.permission\.BLUETOOTH_SCAN[^>]*>',
    ).firstMatch(manifest);
    expect(scanEntry, isNotNull);
    expect(scanEntry!.group(0), contains('neverForLocation'));
  });

  test('location is only requested where old Android needs it', () {
    final fineEntry = RegExp(
      r'<uses-permission[^>]*android\.permission\.ACCESS_FINE_LOCATION[^>]*>',
    ).firstMatch(manifest);
    expect(fineEntry, isNotNull);
    expect(fineEntry!.group(0), contains('android:maxSdkVersion="32"'));
  });

  test('location is not requested on Android 13+ (neverForLocation covers it)', () {
    final root = File(
      'lib/Ahoy/screens/root_screen.dart',
    ).readAsStringSync();
    expect(
      root,
      contains('sdkInt < 33'),
      reason: 'the request list must gate location below Android 13',
    );
    expect(
      root,
      contains('needsLocation && !granted'),
      reason: 'the banner must not fire for an undeclared permission',
    );
  });

  test('release builds block screenshots and recents (audit L-16)', () {
    final activity = File(
      'android/app/src/main/kotlin/com/ahoy/app/MainActivity.kt',
    ).readAsStringSync();
    expect(activity, contains('FLAG_SECURE'));
    expect(activity, contains('!isDebugBuild'),
        reason: 'debug builds stay screenshotable for development');
  });

  test('WiFi Direct inbound connections are capped (ninth review N-5)', () {
    final activity = File(
      'android/app/src/main/kotlin/com/ahoy/app/MainActivity.kt',
    ).readAsStringSync();
    // The accept loop must gate handlers behind a bounded permit set and
    // close sockets beyond it instead of queueing them (spec §8.2).
    expect(activity, contains('MAX_INBOUND_CONNECTIONS = 16'));
    expect(activity, contains('inboundPermits.tryAcquire()'));
    expect(activity, contains('inboundPermits.release()'));
    expect(activity, contains('inbound connection cap reached'));
  });
}
