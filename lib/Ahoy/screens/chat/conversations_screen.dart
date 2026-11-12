import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';
import '../../models/conversation.dart';
import '../../models/nearby_peer.dart';
import '../../widgets/common/transport_badge.dart';
import 'chat_screen.dart';

class ConversationsScreen extends StatelessWidget {
  const ConversationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final convs = chat.conversations;

    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: convs.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 72, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No conversations yet',
                    style: TextStyle(color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Discover nearby people to start chatting',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: convs.length,
              itemBuilder: (ctx, i) => _ConversationTile(conv: convs[i]),
            ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conv;
  const _ConversationTile({required this.conv});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            // Theme-aware surfaces replace pale tints that washed out in
            // dark mode (UI review #21); a blocked thread uses error
            // containers so the state survives theme switches.
            backgroundColor: conv.isBlocked
                ? colorScheme.errorContainer
                : colorScheme.surfaceContainerHighest,
            child: Icon(
              conv.isBlocked ? Icons.block : Icons.person,
              color: conv.isBlocked
                  ? colorScheme.onErrorContainer
                  : colorScheme.onSurfaceVariant,
            ),
          ),
          if (conv.unreadCount > 0)
            Positioned(
              right: -4,
              top: -4,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: colorScheme.error,
                child: Text(
                  '${conv.unreadCount > 9 ? '9+' : conv.unreadCount}',
                  style: TextStyle(fontSize: 12, color: colorScheme.onError),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conv.peerDisplayName,
              style: TextStyle(
                fontWeight: conv.unreadCount > 0
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
          TransportBadge(mode: conv.lastTransport),
        ],
      ),
      subtitle: conv.lastMessagePreview != null
          ? Text(
              conv.isBlocked ? '[Blocked]' : conv.lastMessagePreview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: conv.lastMessageAt != null
          ? Text(
              _formatDate(conv.lastMessageAt!),
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            conversation: conv,
            peer: NearbyPeer(
              uuid: conv.peerUuid,
              shortId: conv.peerShortId,
              displayName: conv.peerDisplayName,
              transport: conv.lastTransport,
              lastSeen: DateTime.now(),
              publicKeyPEM: conv.peerPublicKeyPEM,
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}';
  }
}
