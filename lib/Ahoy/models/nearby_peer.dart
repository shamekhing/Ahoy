import '../core/constants.dart';
import '../core/enums.dart';

class NearbyPeer {
  final String uuid;
  final String shortId;
  final String displayName;
  /// Best/active transport (highest-bandwidth one currently available).
  final TransportMode transport;
  /// All transports via which this peer has been seen — used to render multi-badges.
  final Set<TransportMode> transports;
  final int? rssi;
  final DateTime lastSeen;
  final bool isBlocked;
  final String? statusMessage;
  final String? publicKeyPEM;

  NearbyPeer({
    required this.uuid,
    required this.shortId,
    required this.displayName,
    required this.transport,
    Set<TransportMode>? transports,
    this.rssi,
    required this.lastSeen,
    this.isBlocked = false,
    this.statusMessage,
    this.publicKeyPEM,
  }) : transports = transports ??
            (transport != TransportMode.none ? {transport} : const {});

  NearbyPeer copyWith({
    TransportMode? transport,
    Set<TransportMode>? transports,
    int? rssi,
    DateTime? lastSeen,
    bool? isBlocked,
    String? statusMessage,
    String? publicKeyPEM,
  }) {
    return NearbyPeer(
      uuid: uuid,
      shortId: shortId,
      displayName: displayName,
      transport: transport ?? this.transport,
      transports: transports ?? this.transports,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
      isBlocked: isBlocked ?? this.isBlocked,
      statusMessage: statusMessage ?? this.statusMessage,
      publicKeyPEM: publicKeyPEM ?? this.publicKeyPEM,
    );
  }

  bool get isStale =>
      DateTime.now().difference(lastSeen).inSeconds > AhoyConstants.peerStaleSeconds;
}
