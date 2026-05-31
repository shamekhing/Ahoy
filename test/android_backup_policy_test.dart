import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const backupRulesPath = 'android/app/src/main/res/xml/backup_rules.xml';
  const dataExtractionRulesPath =
      'android/app/src/main/res/xml/data_extraction_rules.xml';

  test('Android app data backup and transfer are disabled', () {
    final manifest = File(manifestPath).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  test('Android backup rules exclude all app-private domains', () {
    final rules = File(backupRulesPath).readAsStringSync();

    expect(rules, contains('<full-backup-content>'));
    _expectExcludedDomains(rules);
  });

  test(
    'Android 12+ extraction rules exclude cloud and device transfer data',
    () {
      final rules = File(dataExtractionRulesPath).readAsStringSync();

      expect(rules, contains('<cloud-backup'));
      expect(rules, contains('<device-transfer>'));
      _expectExcludedDomains(rules);
    },
  );
}

void _expectExcludedDomains(String rules) {
  for (final domain in [
    'root',
    'file',
    'database',
    'sharedpref',
    'external',
    'device_root',
    'device_file',
    'device_database',
    'device_sharedpref',
  ]) {
    expect(rules, contains('<exclude domain="$domain" path="."'));
  }
}
