import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/constants.dart';
import '../core/enums.dart';
import '../core/logging.dart';
import 'crypto/crypto_service.dart';
import 'transport/transport_interface.dart';
import 'transport/wifi_direct_transport.dart';
import 'transport/lan_transport.dart';
import 'transport/ble_transport.dart';

class TransportManager {
  final WiFiDirectTransport _wifiDirect;
  final LanTransport _lan;
  final BleTransport _ble;
  final CryptoService? _crypto;

  final _packetController = StreamController<InboundPacket>.broadcast();
  final _announcementController =
      StreamController<PeerAnnouncement>.broadcast();

  Stream<InboundPacket> get packetStream => _packetController.stream;
  Stream<PeerAnnouncement> get announcementStream =>
      _announcementController.stream;

  final List<StreamSubscription> _subs = [];

  bool _bleEnabled = true;
  bool _lanEnabled = true;
  bool _wifiDirectEnabled = true;

  /// Off the Grid lives here, not in the UI layer, so every advertise path
  /// (cold start, pull-to-refresh, profile edit) is gated in one place
  /// (audit H-3). Scanning stays enabled: off-grid means invisible, not deaf.
  bool _offGrid = false;

  /// Number of advertise passes that actually reached the transports
  /// (tests use this to prove Off the Grid suppresses all of them).
  @visibleForTesting
  int debugAdvertiseCount = 0;

  @visibleForTesting
  void debugRecordTransport(String uuid, TransportMode mode) =>
      _recordTransport(uuid, mode);

  @visibleForTesting
  int get debugRealTransportEntries => _peerTransports.length;

  @visibleForTesting
  int get debugTempTransportEntries => _tempPeerTransports.length;

  bool get offGrid => _offGrid;

  /// Updates the Off the Grid flag. Turning it on stops all advertising
  /// immediately; turning it off does not resume on its own, callers decide
  /// when to broadcast again via [resumeAdvertising] or [refreshAdvertising].
  Future<void> setOffGrid(bool value) async {
    _offGrid = value;
    if (value) {
      await stopAdvertising();
    }
  }

  // Cached identity so individual transport enable/disable can re-advertise
  // without requiring the caller to supply credentials again.
  String? _myUuid;
  String? _myShortId;
  String? _myDisplayName;
  String? _myStatusMessage;
  String? _myPublicKeyPEM;
  String? _myAnnouncementSignature;

  /// peerUuid → set of transports that have seen this peer. Bounded against
  /// forged announcement floods (audit M-8).
  final Map<String, Set<TransportMode>> _peerTransports = {};
  static const int _maxPeerEntries = 512;

  /// Temporary transport identifiers (BT MACs, WFD addresses) live in their
  /// own bounded table (round 8, spec §8): ambient BLE devices must not
  /// churn real peers out of the verified-UUID table above.
  final Map<String, Set<TransportMode>> _tempPeerTransports = {};

  /// tempId → canonicalId alias table.
  /// When a BT MAC or WFD address is resolved to a real Ahoy UUID, we record
  /// the mapping here so sends and incoming packets are routed to the right peer.
  final Map<String, String> _peerAliases = {};

  TransportManager({CryptoService? crypto})
    : _crypto = crypto,
      _wifiDirect = WiFiDirectTransport(),
      _lan = LanTransport(crypto: crypto),
      _ble = BleTransport();

  Future<void> start({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
    required bool bleEnabled,
    required bool lanEnabled,
    required bool wifiDirectEnabled,
    bool offGrid = false,
  }) async {
    _bleEnabled = bleEnabled;
    _lanEnabled = lanEnabled;
    _wifiDirectEnabled = wifiDirectEnabled;
    _offGrid = offGrid;

    _myUuid = uuid;
    _myShortId = shortId;
    _myDisplayName = displayName;
    _myStatusMessage = statusMessage;
    _myPublicKeyPEM = publicKeyPEM;

    _subs.add(_wifiDirect.packetStream.listen(_onPacket));
    _subs.add(_lan.packetStream.listen(_onPacket));
    _subs.add(_ble.packetStream.listen(_onPacket));

    _subs.add(
      _wifiDirect.announcementStream.listen((a) {
        if (!_acceptAnnouncement(a)) return;
        _recordTransport(a.uuid, TransportMode.wifiDirect);
        _announcementController.add(a);
      }),
    );
    _subs.add(
      _lan.announcementStream.listen((a) {
        if (!_acceptAnnouncement(a)) return;
        _recordTransport(a.uuid, TransportMode.lan);
        _announcementController.add(a);
      }),
    );
    _subs.add(
      _ble.announcementStream.listen((a) {
        if (!_acceptAnnouncement(a)) return;
        _recordTransport(a.uuid, TransportMode.ble);
        _announcementController.add(a);
      }),
    );

    await startAdvertising(
      uuid: uuid,
      shortId: shortId,
      displayName: displayName,
      statusMessage: statusMessage,
      publicKeyPEM: publicKeyPEM,
    );

    if (_wifiDirectEnabled) await _wifiDirect.startScanning();
    if (_lanEnabled) await _lan.startScanning();
    if (_bleEnabled) await _ble.startScanning();
  }

  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  }) async {
    // Refresh the cached identity FIRST so the signature always matches the
    // identity being advertised profile edits used to sign the stale name
    // while broadcasting the new one, and receivers dropped us (audit #4).
    _myUuid = uuid;
    _myShortId = shortId;
    _myDisplayName = displayName;
    _myStatusMessage = statusMessage;
    _myPublicKeyPEM = publicKeyPEM;
    _myAnnouncementSignature = _computeAnnouncementSignature();
    if (_offGrid) {
      // Identity fields and the signature stay cached so a later
      // refreshAdvertising() resumes with a correct announcement (audit H-3).
      ahoyLog('[TransportManager] off the grid: not advertising');
      return;
    }
    debugAdvertiseCount += 1;
    if (_wifiDirectEnabled) {
      await _wifiDirect.startAdvertising(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
        announcementSignature: _myAnnouncementSignature,
      );
    }
    if (_lanEnabled) {
      await _lan.startAdvertising(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
        announcementSignature: _myAnnouncementSignature,
      );
    }
    if (_bleEnabled) {
      await _ble.startAdvertising(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
        announcementSignature: _myAnnouncementSignature,
      );
    }
  }

  /// Signs the currently cached identity with the loaded private key.
  /// Returns null when crypto is unavailable or not ready receivers then
  /// treat the announcement as legacy and bind identity at the first chat
  /// message instead.
  String? _computeAnnouncementSignature() {
    final crypto = _crypto;
    if (crypto == null ||
        !crypto.isReady ||
        _myUuid == null ||
        _myPublicKeyPEM == null) {
      return null;
    }
    final timestamp = DateTime.now().toIso8601String();
    debugAnnouncementTimestamp = timestamp;
    return crypto.signAnnouncement(
      uuid: _myUuid!,
      shortId: _myShortId ?? '',
      displayName: _myDisplayName ?? '',
      statusMessage: _myStatusMessage,
      publicKeyPEM: _myPublicKeyPEM,
      timestamp: timestamp,
    );
  }

  /// The announcement signature for the currently cached identity (tests).
  @visibleForTesting
  String? get debugAnnouncementSignature => _myAnnouncementSignature;

  /// The timestamp covered by [debugAnnouncementSignature] (tests).
  @visibleForTesting
  String? debugAnnouncementTimestamp;

  /// Injects a packet as if a transport delivered it (tests).
  @visibleForTesting
  void debugEmitPacket(InboundPacket packet) {
    _onPacket(packet);
  }

  /// Identity-binding gate for announcements (audit #5): routing state and
  /// discovery updates happen only for announcements that pass verification.
  /// Keyless announcements are legitimate only from BLE scan responses.
  ///
  /// LAN and WiFi Direct announcements are each verified twice per cycle:
  /// once here (routing gate) and once in DiscoveryProvider (discovery gate).
  /// Accepted trade-off (fifth review L-8): the two layers own different
  /// state, a single shared verdict would couple their lifetimes, and the
  /// cost is one RSA-2048 verify per peer per 5 s broadcast, which measures
  /// well under a millisecond.
  bool _acceptAnnouncement(PeerAnnouncement announcement) {
    final crypto = _crypto;
    if (crypto == null) return false; // fail closed without verification

    if (!CryptoService.isRealAhoyUuid(announcement.uuid)) {
      // Temporary transport ids (BT MACs) carry no verifiable identity —
      // they are only meaningful on BLE.
      return announcement.transport == TransportMode.ble;
    }
    if (announcement.shortId.isNotEmpty &&
        announcement.shortId.toUpperCase() !=
            CryptoService.shortIdFromUuid(announcement.uuid)) {
      return false;
    }
    if (announcement.publicKeyPEM == null) {
      return announcement.transport == TransportMode.ble;
    }
    final signature = announcement.signature;
    if (signature == null || signature.isEmpty) return false;
    // Freshness: a captured announcement replayed later must not refresh or
    // repoint anything (sixth review, findings 1 and 2).
    if (!CryptoService.isFreshTimestamp(announcement.timestamp)) return false;
    return crypto.verifyAnnouncement(
      uuid: announcement.uuid,
      shortId: announcement.shortId,
      displayName: announcement.displayName,
      statusMessage: announcement.statusMessage,
      publicKeyPEM: announcement.publicKeyPEM!,
      signature: signature,
      timestamp: announcement.timestamp!,
    );
  }

  Future<void> stopAdvertising() async {
    await _wifiDirect.stopAdvertising();
    await _lan.stopAdvertising();
    await _ble.stopAdvertising();
  }

  /// Re-advertise on all enabled transports using the cached identity.
  /// Call this when coming back from off-grid mode. Suppressed while the
  /// Off the Grid flag is still set (audit H-3).
  Future<void> resumeAdvertising() async {
    if (_myUuid == null || _offGrid) return;
    await startAdvertising(
      uuid: _myUuid!,
      shortId: _myShortId!,
      displayName: _myDisplayName!,
      statusMessage: _myStatusMessage,
      publicKeyPEM: _myPublicKeyPEM,
    );
  }

  /// Re-advertises with the cached identity after a profile edit. A no-op
  /// while Off the Grid is on, so editing the profile cannot broadcast the
  /// identity the user asked to hide (audit H-3).
  Future<void> refreshAdvertising() async {
    if (_myUuid == null || _offGrid) return;
    await startAdvertising(
      uuid: _myUuid!,
      shortId: _myShortId!,
      displayName: _myDisplayName!,
      statusMessage: _myStatusMessage,
      publicKeyPEM: _myPublicKeyPEM,
    );
  }

  Future<void> setBleEnabled(bool enabled) async {
    _bleEnabled = enabled;
    if (enabled) {
      await _ble.startScanning();
      if (_myUuid != null && !_offGrid) {
        await _ble.startAdvertising(
          uuid: _myUuid!,
          shortId: _myShortId!,
          displayName: _myDisplayName!,
          statusMessage: _myStatusMessage,
          publicKeyPEM: _myPublicKeyPEM,
          announcementSignature: _myAnnouncementSignature,
        );
      }
    } else {
      await _ble.stopScanning();
      await _ble.stopAdvertising();
    }
  }

  Future<void> setLanEnabled(bool enabled) async {
    _lanEnabled = enabled;
    if (enabled) {
      await _lan.startScanning();
      if (_myUuid != null && !_offGrid) {
        await _lan.startAdvertising(
          uuid: _myUuid!,
          shortId: _myShortId!,
          displayName: _myDisplayName!,
          statusMessage: _myStatusMessage,
          publicKeyPEM: _myPublicKeyPEM,
          announcementSignature: _myAnnouncementSignature,
        );
      }
    } else {
      await _lan.stopScanning();
      await _lan.stopAdvertising();
    }
  }

  Future<void> setWifiDirectEnabled(bool enabled) async {
    _wifiDirectEnabled = enabled;
    if (enabled) {
      await _wifiDirect.startScanning();
      if (_myUuid != null && !_offGrid) {
        await _wifiDirect.startAdvertising(
          uuid: _myUuid!,
          shortId: _myShortId!,
          displayName: _myDisplayName!,
          statusMessage: _myStatusMessage,
          publicKeyPEM: _myPublicKeyPEM,
          announcementSignature: _myAnnouncementSignature,
        );
      }
    } else {
      await _wifiDirect.stopScanning();
      await _wifiDirect.stopAdvertising();
    }
  }

  void _recordTransport(String uuid, TransportMode mode) {
    final isTempId = !CryptoService.isRealAhoyUuid(uuid);
    final table = isTempId ? _tempPeerTransports : _peerTransports;
    final cap = isTempId
        ? AhoyConstants.maxTempPeerEntries
        : _maxPeerEntries;
    table.putIfAbsent(uuid, () => {}).add(mode);
    while (table.length > cap) {
      final oldest = table.keys.first;
      table.remove(oldest);
      if (isTempId) {
        _peerAliases.remove(oldest);
      } else {
        _peerAliases.removeWhere((alias, canonical) => canonical == oldest);
      }
    }
  }

  void _onPacket(InboundPacket packet) {
    // Bind the transport-level id (a BLE MAC) to the canonical UUID the
    // signed payload carries. From here on, routing, sends and discovery
    // agree on one key for this peer (ninth review N-1).
    final boundCanonical = _peerAliases[packet.peerUuid] ?? packet.peerUuid;
    final tempId = packet.transportPeerId;
    if (tempId != null &&
        tempId.isNotEmpty &&
        tempId != boundCanonical &&
        CryptoService.isRealAhoyUuid(boundCanonical)) {
      registerAlias(tempId: tempId, canonicalId: boundCanonical);
    }
    // Resolve any alias so the packet carries the canonical peer UUID.
    final canonical = _peerAliases[packet.peerUuid] ?? packet.peerUuid;
    _recordTransport(canonical, packet.transport);
    if (canonical == packet.peerUuid) {
      _packetController.add(packet);
    } else {
      _packetController.add(
        InboundPacket(
          peerUuid: canonical,
          peerShortId: packet.peerShortId,
          peerDisplayName: packet.peerDisplayName,
          payload: packet.payload,
          transport: packet.transport,
          transportPeerId: packet.transportPeerId,
        ),
      );
    }
  }

  /// Register that [tempId] (a BT/WFD MAC address) is the same physical device
  /// as [canonicalId] (the real Ahoy UUID learned from a higher-fidelity transport).
  /// Merges any accumulated transport info and routes all future traffic correctly.
  void registerAlias({required String tempId, required String canonicalId}) {
    if (tempId == canonicalId) return;
    _peerAliases[tempId] = canonicalId;
    while (_peerAliases.length > _maxPeerEntries) {
      _peerAliases.remove(_peerAliases.keys.first);
    }
    final tempTransports =
        _tempPeerTransports.remove(tempId) ?? _peerTransports.remove(tempId);
    if (tempTransports != null) {
      _peerTransports.putIfAbsent(canonicalId, () => {}).addAll(tempTransports);
    }
  }

  /// Remove a peer that has gone stale, freeing routing state.
  void removePeer(String peerUuid) {
    _peerTransports.remove(peerUuid);
    _tempPeerTransports.remove(peerUuid);
    // Remove reverse alias entries that pointed to this uuid.
    _peerAliases.removeWhere((_, v) => v == peerUuid);
  }

  /// Returns the best currently available transport for a peer.
  TransportMode currentModeFor(String peerUuid) {
    final canonical = _peerAliases[peerUuid] ?? peerUuid;
    final modes = _peerTransports[canonical] ?? _tempPeerTransports[canonical];
    if (modes == null || modes.isEmpty) return TransportMode.none;
    if (modes.contains(TransportMode.wifiDirect)) {
      return TransportMode.wifiDirect;
    }
    if (modes.contains(TransportMode.lan)) return TransportMode.lan;
    if (modes.contains(TransportMode.ble)) return TransportMode.ble;
    return TransportMode.none;
  }

  /// The canonical UUID for [uuid], following any learned temp-id alias
  /// (ninth review N-1). Callers key conversations, trust and the retry
  /// outbox under the canonical id once it is known.
  String canonicalUuid(String uuid) => _peerAliases[uuid] ?? uuid;

  /// The temporary transport id (a Bluetooth MAC) bound to [canonicalUuid],
  /// or null when the peer was never seen under a temporary id. Reverse
  /// lookup over the bounded alias table (ninth review N-1).
  String? tempIdFor(String canonicalUuid) {
    for (final entry in _peerAliases.entries) {
      if (entry.value == canonicalUuid) return entry.key;
    }
    return null;
  }

  /// Send payload to peer, selecting the best available transport.
  Future<bool> send(
    String peerUuid,
    String fromUuid,
    String fromShortId,
    String fromName,
    Map<String, dynamic> data,
  ) async {
    final canonical = _peerAliases[peerUuid] ?? peerUuid;
    // Only the routing UUID rides outside the encrypted payload (audit M-1):
    // display identity and all metadata now live inside the signed/encrypted
    // body. fromShortId/fromName remain in the signature for interface
    // stability but are no longer serialized.
    final payload = jsonEncode({
      ...data,
      'from': fromUuid,
    });
    final mode = currentModeFor(canonical);
    switch (mode) {
      case TransportMode.wifiDirect:
        return _wifiDirect.send(canonical, payload);
      case TransportMode.lan:
        return _lan.send(canonical, payload);
      case TransportMode.ble:
        return _ble.send(canonical, payload);
      case TransportMode.none:
        return false;
    }
  }

  Future<void> stopAll() async {
    await stopAdvertising();
    await _wifiDirect.stopScanning();
    await _lan.stopScanning();
    await _ble.stopScanning();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _peerTransports.clear();
    _tempPeerTransports.clear();
    _peerAliases.clear();
    _myUuid = null;
    _myShortId = null;
    _myDisplayName = null;
    _myStatusMessage = null;
    _myPublicKeyPEM = null;
  }

  Future<void> dispose() async {
    await stopAll();
    await _wifiDirect.dispose();
    await _lan.dispose();
    await _ble.dispose();
    _packetController.close();
    _announcementController.close();
  }
}
