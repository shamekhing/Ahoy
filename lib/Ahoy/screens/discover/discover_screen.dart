import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/discovery_provider.dart';
import '../../models/nearby_peer.dart';
import '../../models/conversation.dart';
import '../../services/chat/message_store.dart';
import '../../widgets/discover/peer_card.dart';
import '../chat/chat_screen.dart';
import '../profile/peer_profile_screen.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final discovery = context.watch<DiscoveryProvider>();
    final peers = discovery.peers.where((p) => !p.isBlocked).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        /*actions: [
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Discovery settings',
              onPressed: () => _showControls(ctx),
            ),
          ),
        ],*/
      ),
      body: Column(
        children: [
          if (discovery.offGrid)
            _Banner(
              icon: Icons.cloud_off,
              message: 'Off the Grid — you are invisible to others',
              color: Colors.grey.shade700,
            ),
          if (discovery.receiveOff)
            _Banner(
              icon: Icons.do_not_disturb,
              message: 'Receive Off — new chat requests are blocked',
              color: Colors.orange.shade700,
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => context.read<DiscoveryProvider>().refreshPeers(),
              child: peers.isEmpty
                  ? SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: MediaQuery.of(context).size.height * 0.6,
                        child: _EmptyState(offGrid: discovery.offGrid),
                      ),
                    )
                  : ListView.builder(
                      itemCount: peers.length,
                      itemBuilder: (ctx, i) => PeerCard(
                        peer: peers[i],
                        onConnect: () => _openChat(ctx, peers[i]),
                        onViewProfile: () => _viewProfile(ctx, peers[i]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _openChat(BuildContext context, NearbyPeer peer) {
    final auth = context.read<AuthProvider>();
    final myUuid = auth.user?.id ?? '';
    final convId = MessageStore.conversationId(myUuid, peer.uuid);

    final chatProvider = context.read<ChatProvider>();
    // Ensure conversation exists
    final existing = chatProvider.conversations.firstWhere(
      (c) => c.id == convId,
      orElse: () => Conversation(
        id: convId,
        peerUuid: peer.uuid,
        peerDisplayName: peer.displayName,
        peerShortId: peer.shortId,
        peerPublicKeyPEM: peer.publicKeyPEM,
        lastTransport: peer.transport,
        createdAt: DateTime.now(),
      ),
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversation: existing, peer: peer),
      ),
    );
  }

  void _viewProfile(BuildContext context, NearbyPeer peer) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PeerProfileScreen(peer: peer)),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color color;

  const _Banner({
    required this.icon,
    required this.message,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: color,
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool offGrid;
  const _EmptyState({required this.offGrid});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            offGrid ? Icons.cloud_off : Icons.radar,
            size: 72,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          Text(
            offGrid ? 'You are off the grid' : 'No peers nearby',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Text(
            offGrid
                ? 'Turn off "Off the Grid" to become discoverable'
                : 'Move closer to other Ahoy users',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
