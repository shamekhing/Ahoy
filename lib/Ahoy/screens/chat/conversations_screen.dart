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
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: conv.isBlocked
                ? Colors.red.shade100
                : Colors.blue.shade100,
            child: Icon(
              conv.isBlocked ? Icons.block : Icons.person,
              color: conv.isBlocked ? Colors.red : Colors.blue,
            ),
          ),
          if (conv.unreadCount > 0)
            Positioned(
              right: -4,
              top: -4,
              child: CircleAvatar(
                radius: 9,
                backgroundColor: Colors.red,
                child: Text(
                  '${conv.unreadCount > 9 ? '9+' : conv.unreadCount}',
                  style: const TextStyle(fontSize: 10, color: Colors.white),
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
              style: const TextStyle(fontSize: 11, color: Colors.grey),
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
