import 'dart:async';
import '../../models/nearby_peer.dart';
import '../../core/enums.dart';
import '../transport/transport_interface.dart';

class DiscoveryService {
  final _peers = <String, NearbyPeer>{};
  final _controller = StreamController<List<NearbyPeer>>.broadcast();
  Timer? _cleanupTimer;

  Stream<List<NearbyPeer>> get peerStream => _controller.stream;
  List<NearbyPeer> get currentPeers => List.unmodifiable(_peers.values.toList());

  void onAnnouncement(PeerAnnouncement announcement, Set<String> blockedUuids) {
    final existing = _peers[announcement.uuid];
    _peers[announcement.uuid] = NearbyPeer(
      uuid: announcement.uuid,
      shortId: announcement.shortId,
      displayName: announcement.displayName,
      transport: _bestTransport(existing?.transport, announcement.transport),
      rssi: null,
      lastSeen: DateTime.now(),
      isBlocked: blockedUuids.contains(announcement.uuid),
      statusMessage: announcement.statusMessage,
      publicKeyPEM: announcement.publicKeyPEM ?? existing?.publicKeyPEM,
    );
    _emit();
  }

  TransportMode _bestTransport(TransportMode? existing, TransportMode incoming) {
    // Prefer higher-bandwidth transports
    const priority = [TransportMode.wifiDirect, TransportMode.lan, TransportMode.ble, TransportMode.none];
    final existingRank = existing != null ? priority.indexOf(existing) : 999;
    final incomingRank = priority.indexOf(incoming);
    return incomingRank < existingRank ? incoming : existing ?? incoming;
  }

  void startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) => _cleanup());
  }

  void stopCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  void _cleanup() {
    final staleKeys = _peers.entries
        .where((e) => e.value.isStale)
        .map((e) => e.key)
        .toList();
    for (final key in staleKeys) {
      _peers.remove(key);
    }
    if (staleKeys.isNotEmpty) _emit();
  }

  void updateBlockedStatus(String peerUuid, bool blocked) {
    final peer = _peers[peerUuid];
    if (peer != null) {
      _peers[peerUuid] = peer.copyWith(isBlocked: blocked);
      _emit();
    }
  }

  void clearAll() {
    _peers.clear();
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(currentPeers);
    }
  }

  void dispose() {
    stopCleanupTimer();
    _controller.close();
  }
}
