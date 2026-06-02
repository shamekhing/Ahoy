import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const infoPlistPath = 'ios/Runner/Info.plist';
  const projectPath = 'ios/Runner.xcodeproj/project.pbxproj';
  const appDelegatePath = 'ios/Runner/AppDelegate.swift';

  test('iOS bundle identifiers use the production Ahoy id', () {
    final project = File(projectPath).readAsStringSync();

    expect(project, contains('PRODUCT_BUNDLE_IDENTIFIER = com.ahoy.app;'));
    expect(
      project,
      contains('PRODUCT_BUNDLE_IDENTIFIER = com.ahoy.app.RunnerTests;'),
    );
    expect(project, isNot(contains('com.example')));
    expect(project, isNot(contains('com.ahoy.ahoy')));
  });

  test('iOS declares runtime privacy usage strings', () {
    final plist = File(infoPlistPath).readAsStringSync();

    for (final key in [
      'NSBluetoothAlwaysUsageDescription',
      'NSCameraUsageDescription',
      'NSFaceIDUsageDescription',
      'NSLocalNetworkUsageDescription',
      'NSMicrophoneUsageDescription',
      'NSPhotoLibraryUsageDescription',
    ]) {
      expect(plist, contains('<key>$key</key>'));
    }
  });

  test('iOS local encrypted files are excluded from device backup', () {
    final appDelegate = File(appDelegatePath).readAsStringSync();

    expect(appDelegate, contains('local_file_policy'));
    expect(appDelegate, contains('excludeFromBackup'));
    expect(appDelegate, contains('values.isExcludedFromBackup = true'));
  });
}
