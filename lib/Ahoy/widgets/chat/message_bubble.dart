import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../models/message.dart';
import '../../core/enums.dart';
import '../../services/crypto/local_data_crypto.dart';
import 'fullscreen_image_view.dart';
import 'reply_preview.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final VoidCallback? onReply;
  final VoidCallback? onPlayAudio;

  /// Tap handler for a failed message: retries the queued send (UI review
  /// #11).
  final VoidCallback? onRetry;

  /// While this bubble's voice message is playing: tap stops, and the
  /// progress bar tracks playback (UI review #14).
  final VoidCallback? onStopAudio;
  final bool isPlaying;
  final double? playbackProgress;
  final LocalDataCrypto? localDataCrypto;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onReply,
    this.onPlayAudio,
    this.onRetry,
    this.onStopAudio,
    this.isPlaying = false,
    this.playbackProgress,
    this.localDataCrypto,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onReply,
        // A failed message retries on tap (UI review #11); the tap must not
        // swallow the long-press reply for healthy messages.
        onTap: message.status == MessageStatus.failed && onRetry != null
            ? onRetry
            : null,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMine ? 16 : 4),
              bottomRight: Radius.circular(isMine ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.replyToPreview != null) _buildReplyHeader(textColor),
              _buildContent(context, textColor),
              const SizedBox(height: 2),
              _buildFooter(textColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReplyHeader(Color textColor) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        ReplyPreview.sanitize(message.replyToPreview!),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.7)),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Color textColor) {
    switch (message.type) {
      case MessageType.text:
        return Text(message.content, style: TextStyle(color: textColor));
      case MessageType.image:
        return _buildImage(context, textColor);
      case MessageType.voice:
        return _buildVoice(textColor);
    }
  }

  Widget _buildImage(BuildContext context, Color textColor) {
    if (message.content.isEmpty) {
      return Text(
        '[Image unavailable]',
        style: TextStyle(color: textColor.withValues(alpha: 0.6)),
      );
    }
    final file = File(message.content);
    final crypto = localDataCrypto;
    if (crypto != null && crypto.isEncryptedFilePath(message.content)) {
      // Decrypt asynchronously off the build path (round 7, external review
      // B#10): sync GCM work inside build janks long threads on rebuilds.
      return _EncryptedImage(
        file: file,
        crypto: crypto,
        textColor: textColor,
        onOpen: () => _openFullscreen(context),
      );
    }

    return GestureDetector(
      onTap: () => _openFullscreen(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: file.existsSync()
            ? Image.file(file, width: 200, height: 200, fit: BoxFit.cover)
            : Text(
                '[Image missing]',
                style: TextStyle(color: textColor.withValues(alpha: 0.6)),
              ),
      ),
    );
  }

  /// Fullscreen, zoomable view of the photo (UI review #15).
  void _openFullscreen(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: FullscreenImageView(
          file: File(message.content),
          crypto: localDataCrypto,
        ),
      ),
    );
  }

  Widget _buildVoice(Color textColor) {
    return InkWell(
      onTap: isPlaying ? onStopAudio : onPlayAudio,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPlaying
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                color: textColor,
              ),
              const SizedBox(width: 6),
              Text(
                isPlaying ? 'Playing tap to stop' : 'Voice message',
                style: TextStyle(color: textColor),
              ),
            ],
          ),
          if (isPlaying) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: 160,
              child: LinearProgressIndicator(
                value: playbackProgress,
                minHeight: 3,
                color: textColor,
                backgroundColor: textColor.withValues(alpha: 0.25),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFooter(Color textColor) {
    final time = _formatTime(message.timestamp);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          time,
          style: TextStyle(
            fontSize: 12,
            color: textColor.withValues(alpha: 0.85),
          ),
        ),
        if (isMine) ...[
          const SizedBox(width: 4),
          // The status glyph carries its meaning in a tooltip (UI review
          // #11): the clock can mean several things and the cross invites a
          // tap-to-retry.
          Tooltip(
            message: _statusTooltip,
            child: Icon(
              _statusIcon,
              size: 14,
              color: textColor.withValues(alpha: 0.85),
            ),
          ),
        ],
      ],
    );
  }

  String get _statusTooltip => switch (message.status) {
    MessageStatus.sending => 'Queued waiting for the peer',
    MessageStatus.sent => 'Sent',
    MessageStatus.delivered => 'Delivered',
    MessageStatus.failed => 'Failed tap to retry',
  };

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  IconData get _statusIcon => switch (message.status) {
    MessageStatus.sending => Icons.schedule,
    MessageStatus.sent => Icons.done,
    MessageStatus.delivered => Icons.done_all,
    MessageStatus.failed => Icons.error_outline,
  };
}

/// Decrypts an at-rest-encrypted media file once, off the build path, and
/// renders it when ready (round 7, external review B#10).
class _EncryptedImage extends StatefulWidget {
  final File file;
  final LocalDataCrypto crypto;
  final Color textColor;
  final VoidCallback onOpen;

  const _EncryptedImage({
    required this.file,
    required this.crypto,
    required this.textColor,
    required this.onOpen,
  });

  @override
  State<_EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<_EncryptedImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.crypto.readEncryptedFile(widget.file);
      if (!mounted) return;
      setState(() {
        // An empty result means the file was quarantined: nothing to show.
        _bytes = bytes.isEmpty ? null : bytes;
        _failed = bytes.isEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unavailable = Text(
      '[Image unavailable]',
      style: TextStyle(color: widget.textColor.withValues(alpha: 0.6)),
    );
    if (_failed) return unavailable;
    final bytes = _bytes;
    if (bytes == null) {
      return const SizedBox(
        width: 200,
        height: 200,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return GestureDetector(
      onTap: widget.onOpen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, width: 200, height: 200, fit: BoxFit.cover),
      ),
    );
  }
}
