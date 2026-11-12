import '../core/enums.dart';

class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final MessageType type;
  final String content;
  final String? replyToId;
  final String? replyToPreview;
  final MessageStatus status;
  final TransportMode transport;
  final DateTime timestamp;

  /// Receiver-clock time used for thread ordering (round 7). The sender
  /// controls [timestamp] and may skew it within the freshness window, so
  /// display order must not trust it. Null on messages stored by older
  /// builds; they fall back to [timestamp].
  final DateTime? receivedAt;
  final bool isEncrypted;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    required this.content,
    this.replyToId,
    this.replyToPreview,
    required this.status,
    required this.transport,
    required this.timestamp,
    this.receivedAt,
    this.isEncrypted = true,
  });

  Message copyWith({
    String? content,
    MessageStatus? status,
    DateTime? receivedAt,
  }) {
    return Message(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      type: type,
      content: content ?? this.content,
      replyToId: replyToId,
      replyToPreview: replyToPreview,
      status: status ?? this.status,
      transport: transport,
      timestamp: timestamp,
      receivedAt: receivedAt ?? this.receivedAt,
      isEncrypted: isEncrypted,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'senderId': senderId,
    'type': type.name,
    'content': content,
    'replyToId': replyToId,
    'replyToPreview': replyToPreview,
    'status': status.name,
    'transport': transport.name,
    'timestamp': timestamp.toIso8601String(),
    if (receivedAt != null) 'receivedAt': receivedAt!.toIso8601String(),
    'isEncrypted': isEncrypted,
  };

  factory Message.fromJson(Map<String, dynamic> json) {
    T parseEnum<T extends Enum>(
      dynamic value,
      List<T> enumValues,
      T defaultValue,
    ) {
      try {
        if (value == null) return defaultValue;
        if (value is String) return enumValues.byName(value);
        if (value is int) {
          if (value >= 0 && value < enumValues.length) {
            return enumValues[value];
          }
        }
        return defaultValue;
      } catch (e) {
        return defaultValue;
      }
    }

    return Message(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      senderId: json['senderId'] as String,
      type: parseEnum(json['type'], MessageType.values, MessageType.text),
      content: json['content'] as String,
      replyToId: json['replyToId'] as String?,
      replyToPreview: json['replyToPreview'] as String?,
      status: parseEnum(
        json['status'],
        MessageStatus.values,
        MessageStatus.sent,
      ),
      transport: parseEnum(
        json['transport'],
        TransportMode.values,
        TransportMode.none,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      receivedAt: json['receivedAt'] == null
          ? null
          : DateTime.parse(json['receivedAt'] as String),
      isEncrypted: json['isEncrypted'] as bool? ?? false,
    );
  }
}
