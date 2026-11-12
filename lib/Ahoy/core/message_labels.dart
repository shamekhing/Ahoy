import 'enums.dart';
import '../models/message.dart';

/// Human-facing one-line label for a message, shared by reply quotes and
/// conversation-list previews (UI review #26). Media content is a local
/// file path that must never surface as text (UI review #1).
class MessageLabels {
  static String forMessage(Message message) {
    switch (message.type) {
      case MessageType.image:
        return '[Photo]';
      case MessageType.voice:
        return '[Voice message]';
      case MessageType.text:
        final content = message.content;
        return content.length > 80 ? '${content.substring(0, 80)}…' : content;
    }
  }
}
