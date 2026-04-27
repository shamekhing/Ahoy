import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/transport_provider.dart';
import '../../providers/discovery_provider.dart';
import '../../models/conversation.dart';
import '../../models/nearby_peer.dart';
import '../../models/message.dart';
import '../../core/enums.dart';
import '../../services/media/media_service.dart';
import '../../widgets/common/transport_badge.dart';
import '../../widgets/chat/message_bubble.dart';
import '../../widgets/chat/message_input_bar.dart';
import '../../widgets/chat/reply_preview.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final NearbyPeer peer;

  const ChatScreen({super.key, required this.conversation, required this.peer});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollCtrl = ScrollController();
  Message? _replyTo;

  late Conversation _conv;

  @override
  void initState() {
    super.initState();
    _conv = widget.conversation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().markRead(_conv.id);
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendText(String text) async {
    final auth = context.read<AuthProvider>();
    final chat = context.read<ChatProvider>();
    await chat.sendMessage(
      myUuid: auth.user!.id,
      myShortId: auth.user!.shortId,
      myDisplayName: auth.user!.username,
      peerUuid: _conv.peerUuid,
      type: MessageType.text,
      content: text,
      replyToId: _replyTo?.id,
      replyToPreview: _replyTo == null
          ? null
          : (_replyTo!.content.length > 80 ? '${_replyTo!.content.substring(0, 80)}…' : _replyTo!.content),
    );
    setState(() => _replyTo = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _sendImage(String path) async {
    final auth = context.read<AuthProvider>();
    final chat = context.read<ChatProvider>();
    await chat.sendMessage(
      myUuid: auth.user!.id,
      myShortId: auth.user!.shortId,
      myDisplayName: auth.user!.username,
      peerUuid: _conv.peerUuid,
      type: MessageType.image,
      content: path,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _toggleRecord() async {
    final media = context.read<MediaService>();
    if (media.isRecording) {
      final path = await media.stopRecording();
      if (!mounted) return;
      if (path != null) {
        final auth = context.read<AuthProvider>();
        final chat = context.read<ChatProvider>();
        await chat.sendMessage(
          myUuid: auth.user!.id,
          myShortId: auth.user!.shortId,
          myDisplayName: auth.user!.username,
          peerUuid: _conv.peerUuid,
          type: MessageType.voice,
          content: path,
        );
      }
    } else {
      await media.startRecording();
    }
    if (mounted) setState(() {});
  }

  void _showOptions() {
    final chat = context.read<ChatProvider>();
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_conv.isBlocked)
              ListTile(
                leading: const Icon(Icons.block, color: Colors.red),
                title: const Text('Block', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(context);
                  final discovery = context.read<DiscoveryProvider>();
                  await chat.blockConversation(_conv.id);
                  discovery.blockPeer(_conv.peerUuid);
                  if (mounted) Navigator.pop(context);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Unblock'),
                onTap: () async {
                  Navigator.pop(context);
                  final discovery = context.read<DiscoveryProvider>();
                  await chat.unblockConversation(_conv.id);
                  discovery.unblockPeer(_conv.peerUuid);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete Conversation', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(context);
                await _confirmDelete(chat);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(ChatProvider chat) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: const Text('All messages will be permanently deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await chat.deleteConversation(_conv.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final transport = context.watch<TransportProvider>();
    final media = context.read<MediaService>();

    final myUuid = auth.user?.id ?? '';
    final messages = chat.messagesFor(_conv.id);
    final mode = transport.modeFor(_conv.peerUuid);
    final canMedia = transport.canSendMedia(_conv.peerUuid);

    // Update conversation reference if provider has updated version
    final updated = chat.conversations.firstWhere(
      (c) => c.id == _conv.id,
      orElse: () => _conv,
    );
    _conv = updated;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_conv.peerDisplayName),
            TransportBadge(mode: mode),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: _showOptions),
        ],
      ),
      body: _conv.isBlocked
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.block, size: 64, color: Colors.red),
                  SizedBox(height: 12),
                  Text('This conversation is blocked'),
                ],
              ),
            )
          : Column(
              children: [
                if (chat.error != null)
                  MaterialBanner(
                    content: Text(chat.error!),
                    actions: [
                      TextButton(onPressed: chat.clearError, child: const Text('Dismiss')),
                    ],
                  ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (ctx, i) {
                      final msg = messages[i];
                      return MessageBubble(
                        message: msg,
                        isMine: msg.senderId == myUuid,
                        onReply: () => setState(() => _replyTo = msg),
                        onPlayAudio: msg.type == MessageType.voice
                            ? () => media.playAudio(msg.content)
                            : null,
                      );
                    },
                  ),
                ),
                if (_replyTo != null)
                  ReplyPreview(
                    preview: _replyTo!.content.length > 80
                        ? '${_replyTo!.content.substring(0, 80)}…'
                        : _replyTo!.content,
                    onClear: () => setState(() => _replyTo = null),
                  ),
                MessageInputBar(
                  canSendMedia: canMedia,
                  isRecording: media.isRecording,
                  onSendText: _sendText,
                  onPickImage: () async {
                    final path = await media.pickImage();
                    if (path != null) _sendImage(path);
                  },
                  onCapturePhoto: () async {
                    final path = await media.capturePhoto();
                    if (path != null) _sendImage(path);
                  },
                  onToggleRecord: _toggleRecord,
                ),
              ],
            ),
    );
  }
}
