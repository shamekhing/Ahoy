import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ninth review device-install follow-up: the auth logo shipped as a PNG
/// with C2PA metadata under an `.svg` name, so `SvgPicture.asset` threw an
/// XmlParserException on every launch. Every declared asset must actually
/// be the format its extension claims, and every declared asset must exist.
List<String> _declaredAssets() {
  final assets = <String>[];
  var inAssets = false;
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
    if (line.trim() == 'assets:') {
      inAssets = true;
      continue;
    }
    if (inAssets) {
      final trimmed = line.trim();
      if (trimmed.startsWith('- ')) {
        assets.add(trimmed.substring(2).trim());
      } else if (trimmed.isNotEmpty) {
        inAssets = false;
      }
    }
  }
  return assets;
}

void main() {
  test('every declared asset exists and matches its extension', () {
    final assets = _declaredAssets();
    expect(assets, isNotEmpty, reason: 'the app ships at least one asset');

    for (final path in assets) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: 'missing asset: $path');

      final bytes = file.readAsBytesSync();
      if (path.endsWith('.svg')) {
        final head = utf8.decode(bytes.sublist(0, bytes.length < 512 ? bytes.length : 512));
        expect(
          head.startsWith('<?xml') || head.contains('<svg'),
          isTrue,
          reason: '$path is declared as SVG but is not XML',
        );
      } else if (path.endsWith('.png')) {
        final magic = bytes.sublist(0, 8);
        expect(
          magic,
          orderedEquals([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          reason: '$path is declared as PNG but lacks the PNG signature',
        );
      }
    }
  });

  test('the auth logo is a real PNG loaded as an image', () {
    final bytes = File('assets/auth_logo.png').readAsBytesSync();
    expect(
      bytes.sublist(0, 8),
      orderedEquals([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    );
    // The renderer is Image.asset now: no SVG loader may remain in the auth
    // screens, and the misnamed asset must be gone.
    final authSources = Directory('lib/Ahoy/screens/auth')
        .listSync()
        .whereType<File>()
        .map((f) => f.readAsStringSync())
        .join('\n');
    expect(authSources, isNot(contains('SvgPicture')));
    expect(authSources, isNot(contains('app_icon.svg')));
    expect(authSources, contains('assets/auth_logo.png'));
  });
}
