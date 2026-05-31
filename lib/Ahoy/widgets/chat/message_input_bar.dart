import 'package:flutter/material.dart';

class MessageInputBar extends StatefulWidget {
  final bool canSendMedia;
  final bool isRecording;
  final void Function(String text) onSendText;
  final VoidCallback onPickImage;
  final VoidCallback onCapturePhoto;
  final VoidCallback onToggleRecord;

  const MessageInputBar({
    super.key,
    required this.canSendMedia,
    required this.isRecording,
    required this.onSendText,
    required this.onPickImage,
    required this.onCapturePhoto,
    required this.onToggleRecord,
  });

  @override
  State<MessageInputBar> createState() => _MessageInputBarState();
}

class _MessageInputBarState extends State<MessageInputBar> {
  final _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSendText(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          children: [
            if (widget.canSendMedia) ...[
              IconButton(
                icon: const Icon(Icons.photo_library_outlined),
                tooltip: 'Photo from gallery',
                onPressed: widget.onPickImage,
              ),
              IconButton(
                icon: const Icon(Icons.camera_alt_outlined),
                tooltip: 'Capture photo',
                onPressed: widget.onCapturePhoto,
              ),
              IconButton(
                icon: Icon(
                  widget.isRecording ? Icons.stop_circle : Icons.mic_outlined,
                  color: widget.isRecording ? Colors.red : null,
                ),
                tooltip: widget.isRecording
                    ? 'Stop recording'
                    : 'Voice message',
                onPressed: widget.onToggleRecord,
              ),
            ],
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: widget.canSendMedia
                      ? 'Message…'
                      : 'Text only (BLE mode)',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: _hasText ? _send : null,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}
