import 'package:flutter/material.dart';
import '../../models/nearby_peer.dart';
import '../../services/crypto/peer_trust_store.dart';
import '../common/peer_avatar.dart';
import '../common/trust_state_sheet.dart';
import '../common/transport_badge.dart';

class PeerCard extends StatelessWidget {
  final NearbyPeer peer;
  final VoidCallback onConnect;
  final VoidCallback? onViewProfile;

  /// How strongly this peer's key is trusted this session (audit H-2).
  /// Null when the peer has no key yet, e.g. a BLE-only sighting.
  final PeerTrustState? trustState;

  const PeerCard({
    super.key,
    required this.peer,
    required this.onConnect,
    this.onViewProfile,
    this.trustState,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: PeerAvatar(
          name: peer.displayName,
          shortId: peer.shortId,
          radius: 22,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                peer.displayName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            // Tappable trust markers (UI review #17): a long-press tooltip is
            // undiscoverable on mobile and the default unverified state needs
            // an explanation, not a silent warning.
            if (trustState == PeerTrustState.unverified)
              IconButton(
                icon: const Icon(
                  Icons.help_outline,
                  size: 18,
                  color: Colors.orange,
                ),
                tooltip: 'What does this mean?',
                onPressed: () => showTrustStateSheet(
                  context,
                  state: trustState,
                  peerName: peer.displayName,
                ),
              )
            else if (trustState == PeerTrustState.verifiedBySafetyNumber)
              IconButton(
                icon: const Icon(
                  Icons.verified_user,
                  size: 18,
                  color: Colors.green,
                ),
                tooltip: 'What does this mean?',
                onPressed: () => showTrustStateSheet(
                  context,
                  state: trustState,
                  peerName: peer.displayName,
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (peer.statusMessage != null && peer.statusMessage!.isNotEmpty)
              Text(peer.statusMessage!, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            TransportBadges(transports: peer.transports),
          ],
        ),
        isThreeLine:
            peer.statusMessage != null && peer.statusMessage!.isNotEmpty,
        trailing: peer.isBlocked
            ? Icon(
                Icons.block,
                color: Theme.of(context).colorScheme.error,
              )
            : TextButton(onPressed: onConnect, child: const Text('Chat')),
        onTap: onViewProfile,
      ),
    );
  }
}
