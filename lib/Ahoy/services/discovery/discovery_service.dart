import 'dart:async';
import '../../models/nearby_peer.dart';
import '../../core/enums.dart';
import '../transport/transport_interface.dart';

/// Result returned when onAnnouncement discovers that a temporary peer ID
/// (e.g. a Bluetooth MAC address) maps to a known canonical Ahoy UUID.
/// The caller should register this alias in TransportManager.
class PeerAlias {
  final String tempId;
  final String canonicalId;
  const PeerAlias({required this.tempId, required this.canonicalId});
}

class DiscoveryService {
  final _peers = <String, NearbyPeer>{};

  /// shortId → canonical Ahoy UUID (persists across peer staleness so
  /// re-discovered peers are still correlated correctly).
  final _shortIdToUuid = <String, String>{};

  final _controller = StreamController<List<NearbyPeer>>.broadcast();
  Timer? _cleanupTimer;
  void Function(List<String> removedUuids)? _onRemoved;

  Stream<List<NearbyPeer>> get peerStream => _controller.stream;
  List<NearbyPeer> get currentPeers => List.unmodifiable(_peers.values.toList());

  /// Process a peer announcement from any transport.
  ///
  /// Returns a [PeerAlias] when a temporary ID (BT/WiFiDirect MAC) is merged
  /// into a canonical Ahoy UUID that was learned from a higher-fidelity transport.
  /// The caller must pass this to TransportManager.registerAlias() so sends/receives
  /// are routed correctly.
  PeerAlias? onAnnouncement(PeerAnnouncement announcement, Set<String> blockedUuids) {
    PeerAlias? alias;
    String canonicalUuid = announcement.uuid;

    if (announcement.shortId.isNotEmpty) {
      final knownUuid = _shortIdToUuid[announcement.shortId];

      if (knownUuid != null) {
        // We already know the canonical UUID for this shortId.
        // Map temporary IDs (MAC addresses) to the canonical one.
        if (knownUuid != announcement.uuid) {
          alias = PeerAlias(tempId: announcement.uuid, canonicalId: knownUuid);
          canonicalUuid = knownUuid;
        }
      } else if (_isRealUuid(announcement.uuid)) {
        // This announcement carries the real Ahoy UUID — record the mapping.
        _shortIdToUuid[announcement.shortId] = announcement.uuid;

        // Scan for an existing temp-ID entry with the same shortId and absorb it.
        final tempEntry = _peers.entries
            .where((e) =>
                e.value.shortId == announcement.shortId &&
                e.key != announcement.uuid)
            .toList();
        for (final e in tempEntry) {
          alias = PeerAlias(tempId: e.key, canonicalId: announcement.uuid);
          // Carry forward any transports that were already recorded for the temp id.
          final merged = <TransportMode>{...e.value.transports, announcement.transport};
          _peers.remove(e.key);
          // We'll write the merged transports below under the canonical UUID.
          final existingBest = e.value.transport;
          final best = _bestTransport(existingBest, announcement.transport);
          _peers[canonicalUuid] = NearbyPeer(
            uuid: canonicalUuid,
            shortId: announcement.shortId,
            displayName: announcement.displayName.isNotEmpty
                ? announcement.displayName
                : e.value.displayName,
            transport: best,
            transports: merged,
            lastSeen: DateTime.now(),
            isBlocked: blockedUuids.contains(canonicalUuid),
            statusMessage: announcement.statusMessage ?? e.value.statusMessage,
            publicKeyPEM: announcement.publicKeyPEM ?? e.value.publicKeyPEM,
          );
          _emit();
          return alias;
        }
      }
    }

    // Normal upsert under the canonical UUID.
    final existing = _peers[canonicalUuid];
    final bestTransport = _bestTransport(existing?.transport, announcement.transport);
    final allTransports = <TransportMode>{
      ...?existing?.transports,
      announcement.transport,
    };
    if (announcement.transport == TransportMode.none) allTransports.remove(TransportMode.none);

    _peers[canonicalUuid] = NearbyPeer(
      uuid: canonicalUuid,
      shortId: announcement.shortId.isNotEmpty
          ? announcement.shortId
          : (existing?.shortId ?? ''),
      displayName: announcement.displayName.isNotEmpty
          ? announcement.displayName
          : (existing?.displayName ?? 'Unknown'),
      transport: bestTransport,
      transports: allTransports,
      lastSeen: DateTime.now(),
      isBlocked: blockedUuids.contains(canonicalUuid),
      statusMessage: announcement.statusMessage ?? existing?.statusMessage,
      publicKeyPEM: announcement.publicKeyPEM ?? existing?.publicKeyPEM,
    );
    _emit();
    return alias;
  }

  TransportMode _bestTransport(TransportMode? existing, TransportMode incoming) {
    const priority = [
      TransportMode.wifiDirect,
      TransportMode.lan,
      TransportMode.ble,
      TransportMode.none,
    ];
    final existingRank = existing != null ? priority.indexOf(existing) : 999;
    final incomingRank = priority.indexOf(incoming);
    return incomingRank < existingRank ? incoming : existing ?? incoming;
  }

  /// Returns true if [uuid] looks like a real Ahoy UUID v4 (not a BT/WFD MAC).
  bool _isRealUuid(String uuid) => RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
      .hasMatch(uuid);

  void startCleanupTimer({void Function(List<String> removedUuids)? onRemoved}) {
    _onRemoved = onRemoved;
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
    if (staleKeys.isNotEmpty) {
      _onRemoved?.call(staleKeys);
      _emit();
    }
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
