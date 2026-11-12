import 'package:flutter/material.dart';
import '../../models/nearby_peer.dart';
import '../../core/enums.dart';
import '../../services/crypto/peer_trust_store.dart';
import '../common/peer_avatar.dart';
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
        leading: PeerAvatar(gender: Gender.unspecified, radius: 22),
        title: Row(
          children: [
            Expanded(
              child: Text(
                peer.displayName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (trustState == PeerTrustState.unverified)
              const Tooltip(
                message: 'Key seen in a self-signed announcement. Compare the '
                    'safety number before trusting this peer.',
                child: Icon(Icons.help_outline,
                    size: 18, color: Colors.orange),
              )
            else if (trustState == PeerTrustState.verifiedBySafetyNumber)
              const Tooltip(
                message: 'Safety number compared out of band.',
                child:
                    Icon(Icons.verified_user, size: 18, color: Colors.green),
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
            ? const Icon(Icons.block, color: Colors.red)
            : TextButton(onPressed: onConnect, child: const Text('Chat')),
        onTap: onViewProfile,
      ),
    );
  }
}
