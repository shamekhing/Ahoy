import 'dart:io';

import 'package:flutter/services.dart';

class LocalFilePolicy {
  static const MethodChannel _channel = MethodChannel('local_file_policy');

  static Future<void> excludeFromBackup(File file) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('excludeFromBackup', file.path);
    } catch (_) {}
  }
}
