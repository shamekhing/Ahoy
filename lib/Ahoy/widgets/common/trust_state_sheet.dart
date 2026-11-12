import 'package:flutter/material.dart';

import '../../services/crypto/peer_trust_store.dart';

/// Explains what a peer's key-trust state means (UI review #17): the marker
/// in the peer list opens this sheet instead of relying on a long-press
/// tooltip that mobile users never discover.
Future<void> showTrustStateSheet(
  BuildContext context, {
  required PeerTrustState? state,
  required String peerName,
}) {
  final theme = Theme.of(context);
  final (title, body, icon, color) = switch (state) {
    PeerTrustState.unverified => (
      'Identity not verified yet',
      '$peerName announced this key itself. Messages are end-to-end '
          'encrypted, but anyone nearby can announce any identity compare '
          'the safety number on the peer profile to be sure you are talking '
          'to the right person.',
      Icons.help_outline,
      Colors.orange,
    ),
    PeerTrustState.pinned => (
      'Key in use',
      'This peer signed a message you accepted with this key, and the key is '
          'pinned for the conversation. Compare the safety number on the peer '
          'profile to verify it out of band.',
      Icons.key,
      Colors.blue,
    ),
    PeerTrustState.verifiedBySafetyNumber => (
      'Identity verified',
      'You compared safety numbers out of band for this key. Messages from '
          'this peer are sealed to the key you verified.',
      Icons.verified_user,
      Colors.green,
    ),
    null => (
      'No key yet',
      'No public key has been announced for this peer yet (for example a '
          'Bluetooth-only sighting). The key is learned at the first signed '
          'contact.',
      Icons.person_search,
      Colors.grey,
    ),
  };

  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(body, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text(
              'Open the peer profile to see and compare the safety number.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}
