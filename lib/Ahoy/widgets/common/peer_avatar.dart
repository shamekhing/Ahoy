import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../services/crypto/local_data_crypto.dart';

/// Avatar with a photo-first fallback chain (UI review #23): encrypted file,
/// base64, then initials on a color derived deterministically from the
/// peer's shortId so peers keep a stable, non-guessable-into-identity
/// color across restarts without storing anything.
class PeerAvatar extends StatelessWidget {
  final String? avatarPath;
  final String? avatarBase64;

  /// Display name: drives the initials shown when no photo exists.
  final String name;

  /// Drives the fallback color (UI review #23).
  final String shortId;
  final double radius;
  final LocalDataCrypto? localDataCrypto;

  const PeerAvatar({
    super.key,
    this.avatarPath,
    this.avatarBase64,
    required this.name,
    required this.shortId,
    this.radius = 24,
    this.localDataCrypto,
  });

  @override
  Widget build(BuildContext context) {
    ImageProvider? image;

    if (avatarPath != null && File(avatarPath!).existsSync()) {
      final crypto = localDataCrypto;
      if (crypto != null && crypto.isEncryptedFilePath(avatarPath!)) {
        try {
          image = MemoryImage(crypto.readEncryptedFileSync(File(avatarPath!)));
        } catch (_) {}
      } else {
        image = FileImage(File(avatarPath!));
      }
    } else if (avatarBase64 != null && avatarBase64!.isNotEmpty) {
      try {
        image = MemoryImage(base64.decode(avatarBase64!));
      } catch (_) {}
    }

    if (image != null) {
      return CircleAvatar(radius: radius, backgroundImage: image);
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: _bgColor,
      child: Text(
        _initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String get _initials {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return shortId.isNotEmpty
          ? String.fromCharCode(shortId.runes.first).toUpperCase()
          : '?';
    }
    final first = String.fromCharCode(words.first.runes.first).toUpperCase();
    if (words.length == 1) return first;
    final last = String.fromCharCode(words.last.runes.first).toUpperCase();
    return '$first$last';
  }

  /// Deterministic per-peer color derived from the shortId (UI review #23).
  Color get _bgColor {
    const palette = [
      Color(0xFF5B8DEF), // blue
      Color(0xFF7C6FF0), // violet
      Color(0xFF2E9E5B), // green
      Color(0xFFE8710A), // orange
      Color(0xFFD93025), // red
      Color(0xFF1287A8), // teal
      Color(0xFFB657D2), // magenta
      Color(0xFF8A8D0A), // olive
    ];
    if (shortId.isEmpty) return palette[0];
    final index =
        shortId.codeUnits.fold(0, (acc, c) => (acc + c) % palette.length);
    return palette[index];
  }
}
