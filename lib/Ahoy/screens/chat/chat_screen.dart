import 'dart:async';

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
import '../../services/crypto/local_data_crypto.dart';
import '../../services/media/media_service.dart';
import '../../widgets/common/transport_badge.dart'; // TransportBadge + TransportBadges
import '../../widgets/chat/message_bubble.dart';
import '../../widgets/chat/message_input_bar.dart';
import '../../widgets/chat/reply_preview.dart';
import '../profile/peer_profile_screen.dart';
import '../../widgets/chat/encrypted_chat_intro.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final NearbyPeer peer;

  const ChatScreen({super.key, required this.conversation, required this.peer});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  Message? _replyTo;

  // Only the ID is stored; the live Conversation is always looked up from the
  // provider so we never hold a stale snapshot.
  late String _convId;

  // Voice playback state (UI review #14): which bubble is playing and its
  // progress, driven by the MediaService streams.
  String? _playingMessageId;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<void>? _completeSub;
  MediaService? _mediaRef;

  Conversation _currentConv(ChatProvider chat) => chat.conversations.firstWhere(
    (c) => c.id == _convId,
    orElse: () => widget.conversation,
  );

  String? _peerPublicKeyFor(Conversation conv, NearbyPeer livePeer) {
    return conv.peerPublicKeyPEM ?? livePeer.publicKeyPEM;
  }

  @override
  void initState() {
    super.initState();
    _convId = widget.conversation.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().markRead(_convId);
    });
  }

  @override
  void dispose() {
    // Leaving the screen mid-recording discards the recording (UI review
    // #14) and stops playback so the temp file and player are released.
    final media = _mediaRef;
    if (media != null) {
      if (media.isRecording) unawaited(media.cancelRecording());
      if (_playingMessageId != null) unawaited(media.stopAudio());
    }
    _cancelPlaybackSubs();
    super.dispose();
  }

  void _cancelPlaybackSubs() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completeSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _completeSub = null;
  }

  /// Plays or stops one bubble's voice message and wires the progress
  /// streams for its bubble (UI review #14).
  Future<void> _togglePlay(Message msg) async {
    final media = _mediaRef;
    if (media == null) return;
    if (_playingMessageId == msg.id) {
      _cancelPlaybackSubs();
      setState(() => _playingMessageId = null);
      await media.stopAudio();
      return;
    }
    _cancelPlaybackSubs();
    _position = Duration.zero;
    _duration = Duration.zero;
    _positionSub = media.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    _durationSub = media.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d ?? Duration.zero);
    });
    _completeSub = media.onPlaybackComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingMessageId = null;
          _position = Duration.zero;
        });
      }
      _cancelPlaybackSubs();
    });
    setState(() => _playingMessageId = msg.id);
    try {
      await media.playAudio(msg.content);
    } catch (_) {
      _cancelPlaybackSubs();
      if (mounted) setState(() => _playingMessageId = null);
    }
  }

  Future<bool> _sendText(String text) async {
    final auth = context.read<AuthProvider>();
    final chat = context.read<ChatProvider>();
    final conv = _currentConv(chat);
    final discovery = context.read<DiscoveryProvider>();
    final livePeer = discovery.peers.firstWhere(
      (p) => p.uuid == conv.peerUuid,
      orElse: () => widget.peer,
    );
    final sent = await chat.sendMessage(
      myUuid: auth.user!.id,
      myShortId: auth.user!.shortId,
      myDisplayName: auth.user!.username,
      peerUuid: conv.peerUuid,
      peerDisplayName: livePeer.displayName,
      peerShortId: livePeer.shortId,
      type: MessageType.text,
      content: text,
      myPublicKeyPEM: auth.user!.publicKeyPEM,
      peerPublicKeyPEM: _peerPublicKeyFor(conv, livePeer),
      replyToId: _replyTo?.id,
      // Media replies quote a label, never the local file path (UI review #1).
      replyToPreview: _replyTo == null ? null : ReplyPreview.labelFor(_replyTo!),
    );
    if (sent == null) {
      // Failed send: keep the text in the input field and the reply context
      // so nothing the user typed is lost (UI review #2). The failure reason
      // is surfaced through chat.error.
      return false;
    }
    setState(() => _replyTo = null);
    return true;
  }

  Future<void> _sendImage(String path) async {
    final auth = context.read<AuthProvider>();
    final chat = context.read<ChatProvider>();
    final conv = _currentConv(chat);
    final discovery = context.read<DiscoveryProvider>();
    final livePeer = discovery.peers.firstWhere(
      (p) => p.uuid == conv.peerUuid,
      orElse: () => widget.peer,
    );
    await chat.sendMessage(
      myUuid: auth.user!.id,
      myShortId: auth.user!.shortId,
      myDisplayName: auth.user!.username,
      peerUuid: conv.peerUuid,
      peerDisplayName: livePeer.displayName,
      peerShortId: livePeer.shortId,
      type: MessageType.image,
      content: path,
      myPublicKeyPEM: auth.user!.publicKeyPEM,
      peerPublicKeyPEM: _peerPublicKeyFor(conv, livePeer),
    );
  }

  Future<void> _toggleRecord() async {
    final media = _mediaRef!;
    if (media.isRecording) {
      final path = await media.stopRecording();
      if (!mounted) return;
      if (path != null) {
        final auth = context.read<AuthProvider>();
        final chat = context.read<ChatProvider>();
        final conv = _currentConv(chat);
        final discovery = context.read<DiscoveryProvider>();
        final livePeer = discovery.peers.firstWhere(
          (p) => p.uuid == conv.peerUuid,
          orElse: () => widget.peer,
        );
        await chat.sendMessage(
          myUuid: auth.user!.id,
          myShortId: auth.user!.shortId,
          myDisplayName: auth.user!.username,
          peerUuid: conv.peerUuid,
          peerDisplayName: livePeer.displayName,
          peerShortId: livePeer.shortId,
          type: MessageType.voice,
          content: path,
          myPublicKeyPEM: auth.user!.publicKeyPEM,
          peerPublicKeyPEM: _peerPublicKeyFor(conv, livePeer),
        );
      }
    } else {
      final started = await media.startRecording();
      if (!started && mounted) {
        // A denied microphone must not fail silently (UI review #14).
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Microphone permission is needed to record voice messages.',
            ),
          ),
        );
      }
    }
    if (mounted) setState(() {});
  }

  void _showOptions() {
    final chat = context.read<ChatProvider>();
    final conv = _currentConv(chat);
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!conv.isBlocked)
              ListTile(
                leading: Icon(Icons.block, color: Theme.of(context).colorScheme.error),
                title: Text('Block', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  Navigator.pop(context);
                  // Blocking is reversible but disruptive: confirm first
                  // (UI review #13).
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Block peer?'),
                      content: Text(
                        'You will not receive messages from '
                        '${conv.peerDisplayName} until you unblock them.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.error,
                          ),
                          child: const Text('Block'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  if (!mounted) return;
                  final discovery = context.read<DiscoveryProvider>();
                  await chat.blockConversation(conv.id);
                  discovery.blockPeer(conv.peerUuid);
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
                  await chat.unblockConversation(conv.id);
                  discovery.unblockPeer(conv.peerUuid);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text(
                'Delete Conversation',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await chat.deleteConversation(_convId);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final transport = context.watch<TransportProvider>();
    final discovery = context.watch<DiscoveryProvider>();
    final media = context.read<MediaService>();
    final localDataCrypto = context.read<LocalDataCrypto>();

    final myUuid = auth.user?.id ?? '';
    final conv = _currentConv(chat);
    final messages = chat.messagesFor(conv.id);
    final canMedia = transport.canSendMedia(conv.peerUuid);
    _mediaRef ??= media;
    final sendError = chat.errorFor(conv.id);
    // Reachability comes from the routing tables (the truth sends use), not
    // from the discovery list (UI review #10).
    final peerNearby = transport.modeFor(conv.peerUuid) != TransportMode.none;

    // Use live discovery data if the peer is currently visible, so transport
    // badges update in real-time as new transports are discovered.
    final livePeer = discovery.peers.firstWhere(
      (p) => p.uuid == conv.peerUuid,
      orElse: () => widget.peer,
    );

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(conv.peerDisplayName),
            if (peerNearby)
              TransportBadges(transports: livePeer.transports)
            else
              const Text(
                'Not nearby',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
        actions: [
          // The encryption promise is visible in the chat, and the lock leads
          // to the trust surface: the peer's profile with its safety number
          // (UI review #16).
          IconButton(
            icon: const Icon(Icons.lock_outline),
            tooltip: 'End-to-end encrypted — open peer profile',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PeerProfileScreen(peer: livePeer)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: _showOptions,
          ),
        ],
      ),
      body: conv.isBlocked
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.block,
                    size: 64,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 12),
                  const Text('This conversation is blocked'),
                  const SizedBox(height: 16),
                  // The body carries its own unblock path (UI review #13):
                  // the overflow menu alone was a dead end.
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Unblock'),
                    onPressed: () async {
                      final chat = context.read<ChatProvider>();
                      final discovery = context.read<DiscoveryProvider>();
                      await chat.unblockConversation(conv.id);
                      discovery.unblockPeer(conv.peerUuid);
                    },
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (sendError != null)
                  MaterialBanner(
                    content: Text(sendError),
                    actions: [
                      TextButton(
                        onPressed: () => chat.clearError(conv.id),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? EncryptedChatIntro(peerName: conv.peerDisplayName)
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          // Bottom-anchored list (UI review #8): index 0 is
                          // the newest message, the keyboard pushes content
                          // up, and incoming messages appear in place
                          // without scroll jumps.
                          reverse: true,
                          itemCount: messages.length,
                          itemBuilder: (ctx, i) {
                            final msg = messages[messages.length - 1 - i];
                            return MessageBubble(
                              message: msg,
                              isMine: msg.senderId == myUuid,
                              onReply: () => setState(() => _replyTo = msg),
                              onRetry: msg.status == MessageStatus.failed
                                  ? () => chat.retryFor(conv.peerUuid)
                                  : null,
                              onPlayAudio: msg.type == MessageType.voice
                                  ? () => _togglePlay(msg)
                                  : null,
                              onStopAudio: msg.type == MessageType.voice
                                  ? () => _togglePlay(msg)
                                  : null,
                              isPlaying: _playingMessageId == msg.id,
                              playbackProgress:
                                  _duration.inMilliseconds > 0
                                  ? (_position.inMilliseconds /
                                            _duration.inMilliseconds)
                                        .clamp(0.0, 1.0)
                                  : null,
                              localDataCrypto: localDataCrypto,
                            );
                          },
                        ),
                ),
                if (_replyTo != null)
                  ReplyPreview(
                    preview: ReplyPreview.labelFor(_replyTo!),
                    onClear: () => setState(() => _replyTo = null),
                  ),
                MessageInputBar(
                  canSendMedia: canMedia,
                  isRecording: media.isRecording,
                  peerNearby: peerNearby,
                  onSendText: _sendText,
                  onCancelRecording: () async {
                    await media.cancelRecording();
                    if (mounted) setState(() {});
                  },
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
