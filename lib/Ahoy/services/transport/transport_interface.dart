import '../../core/enums.dart';

/// Packet received from a peer over any transport.
class InboundPacket {
  final String peerUuid;
  final String peerShortId;
  final String peerDisplayName;
  final String payload; // JSON string
  final TransportMode transport;

  const InboundPacket({
    required this.peerUuid,
    required this.peerShortId,
    required this.peerDisplayName,
    required this.payload,
    required this.transport,
  });
}

/// Announcement broadcast by a peer for discovery.
class PeerAnnouncement {
  final String uuid;
  final String shortId;
  final String displayName;
  final String? statusMessage;
  final String? publicKeyPEM;
  final TransportMode transport;

  const PeerAnnouncement({
    required this.uuid,
    required this.shortId,
    required this.displayName,
    this.statusMessage,
    this.publicKeyPEM,
    required this.transport,
  });
}

abstract class TransportInterface {
  TransportMode get mode;

  Stream<InboundPacket> get packetStream;
  Stream<PeerAnnouncement> get announcementStream;

  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  });

  Future<void> stopAdvertising();

  Future<void> startScanning();
  Future<void> stopScanning();

  Future<bool> send(String peerUuid, String payload);

  Future<void> dispose();
}
