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
}
