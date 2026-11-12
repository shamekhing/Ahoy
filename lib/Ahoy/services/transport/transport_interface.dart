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

  /// RSA-SHA256 signature over the announcement material, made with
  /// [publicKeyPEM]'s private key. Null for BLE scan-response announcements
  /// (13-byte budget) identity is bound at the first signed chat message.
  final String? signature;

  /// ISO timestamp covered by the signature (sixth review, findings 1 and 2).
  /// Null only for keyless BLE announcements.
  final String? timestamp;
  final TransportMode transport;

  const PeerAnnouncement({
    required this.uuid,
    required this.shortId,
    required this.displayName,
    this.statusMessage,
    this.publicKeyPEM,
    this.signature,
    this.timestamp,
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
    String? announcementSignature,
  });

  Future<void> stopAdvertising();

  Future<void> startScanning();
  Future<void> stopScanning();

  Future<bool> send(String peerUuid, String payload);

  Future<void> dispose();
}
