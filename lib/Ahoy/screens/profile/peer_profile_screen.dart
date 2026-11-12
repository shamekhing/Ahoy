import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/nearby_peer.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/discovery_provider.dart';
import '../../services/crypto/crypto_service.dart';
import '../../services/crypto/peer_trust_store.dart';
import '../../widgets/common/peer_avatar.dart';
import '../../widgets/common/trust_state_sheet.dart';
import '../../widgets/common/transport_badge.dart';

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
    // Theme-aware containers replace hardcoded pale tints that turned
    // near-invisible in dark mode (UI review #21).
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          peer.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (action) => _handleAction(context, action, discovery),
            itemBuilder: (_) => [
              if (!isBlocked)
                PopupMenuItem(
                  value: 'block',
                  child: Text('Block', style: TextStyle(color: colorScheme.error)),
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
          Center(
            child: GestureDetector(
              onTap: () => showTrustStateSheet(
                context,
                state: trust?.state,
                peerName: peer.displayName,
              ),
              child: PeerAvatar(
                name: peer.displayName,
                shortId: peer.shortId,
                radius: 48,
              ),
            ),
          ),
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
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              'short ID is display only compare the safety number to verify',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          if (trust != null) ...[
            const SizedBox(height: 8),
            Center(
              child: GestureDetector(
                onTap: () => showTrustStateSheet(
                  context,
                  state: trust.state,
                  peerName: peer.displayName,
                ),
                child: _TrustChip(state: trust.state),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Center(child: TransportBadges(transports: peer.transports)),
          if (hasKeyChange) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: colorScheme.onTertiaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Identity changed',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A different public key was announced for this peer. '
                    'Messages are still sealed to the key you already know. '
                    'Compare the safety number out of band before trusting '
                    'the new key.',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onTertiaryContainer,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => chat.dismissPeerKeyChange(peer.uuid),
                        child: const Text('Keep current key'),
                      ),
                      TextButton(
                        onPressed: () =>
                            chat.promotePeerBySafetyNumber(peer.uuid),
                        child: const Text('I verified the current key'),
                      ),
                    ],
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Read this number aloud with your peer it is identical on '
                    'both devices for this conversation.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy safety number',
                  onPressed: () {
                    // Capture before the async gap (build context here is
                    // still mounted).
                    final messenger = ScaffoldMessenger.of(context);
                    Clipboard.setData(ClipboardData(text: safetyNumber)).then(
                      (_) => messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Safety number copied.'),
                        ),
                      ),
                    );
                  },
                ),
              ],
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
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.block, color: colorScheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Text(
                    'You have blocked this person',
                    style: TextStyle(color: colorScheme.onErrorContainer),
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
