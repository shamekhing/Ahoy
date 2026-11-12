import 'package:flutter/material.dart';

/// Shown in an empty conversation: makes the end-to-end encryption promise
/// visible inside the chat (UI review #16) instead of hiding it behind the
/// peer profile.
class EncryptedChatIntro extends StatelessWidget {
  final String peerName;

  const EncryptedChatIntro({super.key, required this.peerName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_outline,
            size: 56,
            color: theme.colorScheme.primary.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 12),
          Text(
            'No messages with $peerName yet',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Everything you send here is end-to-end encrypted. Compare the '
              'safety number on the peer profile to verify the connection out '
              'of band.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
