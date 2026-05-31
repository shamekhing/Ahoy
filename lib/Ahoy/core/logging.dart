import 'package:flutter/foundation.dart';

void ahoyLog(String message, [Object? error]) {
  if (!kDebugMode) return;
  if (error == null) {
    debugPrint(message);
  } else {
    debugPrint('$message (${error.runtimeType})');
  }
}
