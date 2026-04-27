import '../core/enums.dart';

class Conversation {
  final String id;
  final String peerUuid;
  final String peerDisplayName;
  final TransportMode lastTransport;
  final bool isBlocked;
  final bool isDeleted;
  final int unreadCount;
  final DateTime createdAt;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;

  const Conversation({
    required this.id,
    required this.peerUuid,
    required this.peerDisplayName,
    required this.lastTransport,
    this.isBlocked = false,
    this.isDeleted = false,
    this.unreadCount = 0,
    required this.createdAt,
    this.lastMessageAt,
    this.lastMessagePreview,
  });

  Conversation copyWith({
    String? peerDisplayName,
    TransportMode? lastTransport,
    bool? isBlocked,
    bool? isDeleted,
    int? unreadCount,
    DateTime? lastMessageAt,
    String? lastMessagePreview,
  }) {
    return Conversation(
      id: id,
      peerUuid: peerUuid,
      peerDisplayName: peerDisplayName ?? this.peerDisplayName,
      lastTransport: lastTransport ?? this.lastTransport,
      isBlocked: isBlocked ?? this.isBlocked,
      isDeleted: isDeleted ?? this.isDeleted,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerUuid': peerUuid,
        'peerDisplayName': peerDisplayName,
        'lastTransport': lastTransport.name,
        'isBlocked': isBlocked,
        'isDeleted': isDeleted,
        'unreadCount': unreadCount,
        'createdAt': createdAt.toIso8601String(),
        'lastMessageAt': lastMessageAt?.toIso8601String(),
        'lastMessagePreview': lastMessagePreview,
      };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    TransportMode _parseTransport(dynamic value) {
      try {
        if (value == null) return TransportMode.none;
        if (value is String) return TransportMode.values.byName(value);
        if (value is int) {
          if (value >= 0 && value < TransportMode.values.length) {
            return TransportMode.values[value];
          }
        }
        return TransportMode.none;
      } catch (e) {
        return TransportMode.none;
      }
    }

    return Conversation(
      id: json['id'] as String,
      peerUuid: json['peerUuid'] as String,
      peerDisplayName: json['peerDisplayName'] as String,
      lastTransport: _parseTransport(json['lastTransport']),
      isBlocked: json['isBlocked'] as bool? ?? false,
      isDeleted: json['isDeleted'] as bool? ?? false,
      unreadCount: json['unreadCount'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastMessageAt: json['lastMessageAt'] != null
          ? DateTime.parse(json['lastMessageAt'] as String)
          : null,
      lastMessagePreview: json['lastMessagePreview'] as String?,
    );
  }
}
