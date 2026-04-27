import '../core/enums.dart';

class NearbyPeer {
  final String uuid;
  final String shortId;
  final String displayName;
  final TransportMode transport;
  final int? rssi;
  final DateTime lastSeen;
  final bool isBlocked;
  final String? statusMessage;
  final String? publicKeyPEM;

  const NearbyPeer({
    required this.uuid,
    required this.shortId,
    required this.displayName,
    required this.transport,
    this.rssi,
    required this.lastSeen,
    this.isBlocked = false,
    this.statusMessage,
    this.publicKeyPEM,
  });

  NearbyPeer copyWith({
    TransportMode? transport,
    int? rssi,
    DateTime? lastSeen,
    bool? isBlocked,
    String? statusMessage,
  }) {
    return NearbyPeer(
      uuid: uuid,
      shortId: shortId,
      displayName: displayName,
      transport: transport ?? this.transport,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
      isBlocked: isBlocked ?? this.isBlocked,
      statusMessage: statusMessage ?? this.statusMessage,
      publicKeyPEM: publicKeyPEM,
    );
  }

  bool get isStale {
    return DateTime.now().difference(lastSeen).inSeconds > 30;
  }
}
