import 'dart:io';
import 'package:flutter/material.dart';
import '../../models/message.dart';
import '../../core/enums.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final VoidCallback? onReply;
  final VoidCallback? onPlayAudio;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onReply,
    this.onPlayAudio,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onReply,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
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
              _buildContent(textColor),
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
        message.replyToPreview!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.7)),
      ),
    );
  }

  Widget _buildContent(Color textColor) {
    switch (message.type) {
      case MessageType.text:
        return Text(message.content, style: TextStyle(color: textColor));
      case MessageType.image:
        return _buildImage(textColor);
      case MessageType.voice:
        return _buildVoice(textColor);
    }
  }

  Widget _buildImage(Color textColor) {
    if (message.content.isEmpty) {
      return Text('[Image unavailable]', style: TextStyle(color: textColor.withValues(alpha: 0.6)));
    }
    final file = File(message.content);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: file.existsSync()
          ? Image.file(file, width: 200, height: 200, fit: BoxFit.cover)
          : Text('[Image missing]', style: TextStyle(color: textColor.withValues(alpha: 0.6))),
    );
  }

  Widget _buildVoice(Color textColor) {
    return InkWell(
      onTap: onPlayAudio,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_circle_outline, color: textColor),
          const SizedBox(width: 6),
          Text('Voice message', style: TextStyle(color: textColor)),
        ],
      ),
    );
  }

  Widget _buildFooter(Color textColor) {
    final time = _formatTime(message.timestamp);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(time, style: TextStyle(fontSize: 10, color: textColor.withValues(alpha: 0.6))),
        if (isMine) ...[
          const SizedBox(width: 4),
          Icon(_statusIcon, size: 12, color: textColor.withValues(alpha: 0.6)),
        ],
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  IconData get _statusIcon => switch (message.status) {
        MessageStatus.sending => Icons.schedule,
        MessageStatus.sent => Icons.done,
        MessageStatus.failed => Icons.error_outline,
      };
}
