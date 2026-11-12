import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/nearby_peer.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/discovery_provider.dart';
import '../../services/crypto/crypto_service.dart';
import '../../services/crypto/peer_trust_store.dart';
import '../../widgets/common/peer_avatar.dart';
import '../../widgets/common/transport_badge.dart';
import '../../core/enums.dart';

class PeerProfileScreen extends StatelessWidget {
  final NearbyPeer peer;

  const PeerProfileScreen({super.key, required this.peer});

  @override
  Widget build(BuildContext context) {
    final discovery = context.watch<DiscoveryProvider>();
    final chat = context.watch<ChatProvider>();
    final me = context.watch<AuthProvider>().user;
    final conversation = context
        .watch<ChatProvider>()
        .conversations
        .where((c) => c.peerUuid == peer.uuid)
        .firstOrNull;
    // The pinned conversation key is what actually protects the messages —
    // prefer it over the (signature-verified) announced key.
    final pinnedKey = conversation?.peerPublicKeyPEM;
    final peerKey = (pinnedKey != null && pinnedKey.isNotEmpty)
        ? pinnedKey
        : peer.publicKeyPEM;
    final safetyNumber = (peerKey != null && peerKey.isNotEmpty)
        ? (me != null
              ? CryptoService.safetyNumberFor(me.publicKeyPEM, peerKey)
              : CryptoService.fingerprintFromPublicKey(peerKey))
        : null;
    final isBlocked = discovery.blockedUuids.contains(peer.uuid);
    final trust = chat.peerTrust(peer.uuid);
    final hasKeyChange = trust?.pendingKey != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(peer.displayName),
        actions: [
          PopupMenuButton<String>(
            onSelected: (action) => _handleAction(context, action, discovery),
            itemBuilder: (_) => [
              if (!isBlocked)
                const PopupMenuItem(
                  value: 'block',
                  child: Text('Block', style: TextStyle(color: Colors.red)),
                )
              else
                const PopupMenuItem(value: 'unblock', child: Text('Unblock')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(child: PeerAvatar(gender: Gender.unspecified, radius: 48)),
          const SizedBox(height: 16),
          Center(
            child: Text(
              peer.displayName,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Center(
            child: Text(
              '@${peer.shortId}',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 4),
          const Center(
            child: Text(
              'short ID is display only compare the safety number to verify',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ),
          if (trust != null) ...[
            const SizedBox(height: 8),
            Center(child: _TrustChip(state: trust.state)),
          ],
          const SizedBox(height: 8),
          Center(child: TransportBadges(transports: peer.transports)),
          if (hasKeyChange) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange),
                      SizedBox(width: 8),
                      Text(
                        'Identity changed',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A different public key was announced for this peer. '
                    'Messages are still sealed to the key you already know. '
                    'Compare the safety number out of band before trusting '
                    'the new key.',
                    style: TextStyle(fontSize: 12),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () =>
                          chat.promotePeerBySafetyNumber(peer.uuid),
                      child: const Text('Mark as verified'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (safetyNumber != null) ...[
            const SizedBox(height: 24),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Safety number',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              safetyNumber,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Read this number aloud with your peer it is identical on '
              'both devices for this conversation.',
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
          if (peer.statusMessage != null && peer.statusMessage!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Center(
              child: Text(
                '"${peer.statusMessage}"',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.grey,
                ),
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
                  Text(
                    'You have blocked this person',
                    style: TextStyle(color: Colors.red),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _handleAction(
    BuildContext context,
    String action,
    DiscoveryProvider discovery,
  ) {
    if (action == 'block') {
      discovery.blockPeer(peer.uuid);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${peer.displayName} blocked')));
    } else if (action == 'unblock') {
      discovery.unblockPeer(peer.uuid);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${peer.displayName} unblocked')));
    }
  }
}

/// Small badge communicating how strongly this peer's key is trusted
/// (audit H-2). Pinned is intentionally unlabelled: it is the normal state
/// after the first signed message.
class _TrustChip extends StatelessWidget {
  final PeerTrustState state;

  const _TrustChip({required this.state});

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case PeerTrustState.verifiedBySafetyNumber:
        return const Chip(
          avatar: Icon(Icons.verified_user, size: 18, color: Colors.green),
          label: Text('Verified by safety number'),
        );
      case PeerTrustState.unverified:
        return const Chip(
          avatar: Icon(Icons.help_outline, size: 18, color: Colors.orange),
          label: Text('Unverified'),
        );
      case PeerTrustState.pinned:
        return const SizedBox.shrink();
    }
  }
}
