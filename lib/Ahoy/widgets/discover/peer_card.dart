import 'package:flutter/material.dart';
import '../../models/nearby_peer.dart';
import '../../core/enums.dart';
import '../common/peer_avatar.dart';
import '../common/transport_badge.dart';

class PeerCard extends StatelessWidget {
  final NearbyPeer peer;
  final VoidCallback onConnect;
  final VoidCallback? onViewProfile;

  const PeerCard({
    super.key,
    required this.peer,
    required this.onConnect,
    this.onViewProfile,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: PeerAvatar(gender: Gender.unspecified, radius: 22),
        title: Text(
          peer.displayName,
          style: const TextStyle(fontWeight: FontWeight.w600),
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
