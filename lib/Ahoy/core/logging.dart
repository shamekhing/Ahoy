import 'package:flutter/foundation.dart';

void ahoyLog(String message, [Object? error]) {
  if (!kDebugMode) return;
  if (error == null) {
    debugPrint(message);
  } else {
    // Full toString: PlatformException codes/messages are the difference
    // between a diagnosis and a dead end in the field.
    debugPrint('$message\n  $error');
  }
}
