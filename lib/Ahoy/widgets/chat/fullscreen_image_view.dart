import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/crypto/local_data_crypto.dart';

/// Fullscreen, zoomable image viewer for a message photo (UI review #15).
/// Decrypts the at-rest file off the build path and shows a loading and an
/// unavailable state.
class FullscreenImageView extends StatefulWidget {
  final File file;
  final LocalDataCrypto? crypto;

  /// Optional loader override (tests inject an immediate loader so widget
  /// tests do not perform real file IO inside fake async). Defaults to the
  /// at-rest decryption path.
  final Future<Uint8List> Function(File)? loader;

  const FullscreenImageView({
    super.key,
    required this.file,
    required this.crypto,
    this.loader,
  });

  @override
  State<FullscreenImageView> createState() => _FullscreenImageViewState();
}

class _FullscreenImageViewState extends State<FullscreenImageView> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Uint8List bytes;
    try {
      final loader = widget.loader ?? _defaultLoad;
      bytes = await loader(widget.file);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!mounted) return;
    setState(() {
      // An empty result means the file was quarantined: nothing to show.
      _bytes = bytes.isEmpty ? null : bytes;
      _failed = bytes.isEmpty;
    });
  }

  Future<Uint8List> _defaultLoad(File file) async {
    final crypto = widget.crypto;
    if (crypto != null && crypto.isEncryptedFilePath(file.path)) {
      return crypto.readEncryptedFile(file);
    }
    return file.readAsBytes();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(
        child: Text(
          'Image unavailable',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    }
    return InteractiveViewer(
      maxScale: 8,
      child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
    );
  }
}
