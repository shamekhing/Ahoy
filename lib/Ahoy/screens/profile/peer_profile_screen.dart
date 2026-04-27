import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/nearby_peer.dart';
import '../../providers/discovery_provider.dart';
import '../../widgets/common/peer_avatar.dart';
import '../../widgets/common/transport_badge.dart';
import '../../core/enums.dart';

class PeerProfileScreen extends StatelessWidget {
  final NearbyPeer peer;

  const PeerProfileScreen({super.key, required this.peer});

  @override
  Widget build(BuildContext context) {
    final discovery = context.watch<DiscoveryProvider>();
    final isBlocked = discovery.blockedUuids.contains(peer.uuid);

    return Scaffold(
      appBar: AppBar(
        title: Text(peer.displayName),
        actions: [
          PopupMenuButton<String>(
            onSelected: (action) => _handleAction(context, action, discovery),
            itemBuilder: (_) => [
              if (!isBlocked)
                const PopupMenuItem(value: 'block', child: Text('Block', style: TextStyle(color: Colors.red)))
              else
                const PopupMenuItem(value: 'unblock', child: Text('Unblock')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: PeerAvatar(
              gender: Gender.unspecified,
              radius: 48,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(peer.displayName,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          ),
          Center(child: Text('@${peer.shortId}', style: const TextStyle(color: Colors.grey))),
          const SizedBox(height: 8),
          Center(child: TransportBadge(mode: peer.transport)),
          if (peer.statusMessage != null && peer.statusMessage!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Center(
              child: Text(
                '"${peer.statusMessage}"',
                textAlign: TextAlign.center,
                style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
              ),
            ),
          ],
          if (isBlocked) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: const Row(
                children: [
                  Icon(Icons.block, color: Colors.red),
                  SizedBox(width: 8),
                  Text('You have blocked this person', style: TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _handleAction(BuildContext context, String action, DiscoveryProvider discovery) {
    if (action == 'block') {
      discovery.blockPeer(peer.uuid);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${peer.displayName} blocked')),
      );
    } else if (action == 'unblock') {
      discovery.unblockPeer(peer.uuid);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${peer.displayName} unblocked')),
      );
    }
  }
}
