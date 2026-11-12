import 'package:flutter/material.dart';

import '../../core/message_labels.dart';
import '../../models/message.dart';

class ReplyPreview extends StatelessWidget {
  final String preview;
  final VoidCallback onClear;

  const ReplyPreview({super.key, required this.preview, required this.onClear});

  /// The quoted-preview text for [message] as it should travel on the wire
  /// and render in the reply bar. Media content is a local file path that
  /// must never leave the device (UI review #1), so media replies quote a
  /// neutral label instead.
  static String labelFor(Message message) => MessageLabels.forMessage(message);

  /// Inbound reply previews are chosen by the peer's client. If an older or
  /// modified client quoted a local file path, render a neutral label
  /// instead of exposing it (UI review #1).
  static String sanitize(String preview) {
    if (preview.contains('/ahoy_media_') || preview.endsWith('.ahoyenc')) {
      return '[Media]';
    }
    return preview;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}
