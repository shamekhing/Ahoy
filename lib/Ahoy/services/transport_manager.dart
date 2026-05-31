import 'dart:async';
import 'dart:convert';
import '../core/enums.dart';
import 'transport/transport_interface.dart';
import 'transport/wifi_direct_transport.dart';
import 'transport/lan_transport.dart';
import 'transport/ble_transport.dart';

class TransportManager {
  final WiFiDirectTransport _wifiDirect;
  final LanTransport _lan;
  final BleTransport _ble;

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

  // Cached identity so individual transport enable/disable can re-advertise
  // without requiring the caller to supply credentials again.
  String? _myUuid;
  String? _myShortId;
  String? _myDisplayName;
  String? _myStatusMessage;
  String? _myPublicKeyPEM;

  /// peerUuid → set of transports that have seen this peer.
  final Map<String, Set<TransportMode>> _peerTransports = {};

  /// tempId → canonicalId alias table.
  /// When a BT MAC or WFD address is resolved to a real Ahoy UUID, we record
  /// the mapping here so sends and incoming packets are routed to the right peer.
  final Map<String, String> _peerAliases = {};

  TransportManager()
    : _wifiDirect = WiFiDirectTransport(),
      _lan = LanTransport(),
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
  }) async {
    _bleEnabled = bleEnabled;
    _lanEnabled = lanEnabled;
    _wifiDirectEnabled = wifiDirectEnabled;

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
        _recordTransport(a.uuid, TransportMode.wifiDirect);
        _announcementController.add(a);
      }),
    );
    _subs.add(
      _lan.announcementStream.listen((a) {
        _recordTransport(a.uuid, TransportMode.lan);
        _announcementController.add(a);
      }),
    );
    _subs.add(
      _ble.announcementStream.listen((a) {
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
    if (_wifiDirectEnabled) {
      await _wifiDirect.startAdvertising(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
      );
    }
    if (_lanEnabled) {
      await _lan.startAdvertising(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
      );
    }
    if (_bleEnabled) {
      await _ble.startAdvertising(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
      );
    }
  }

  Future<void> stopAdvertising() async {
    await _wifiDirect.stopAdvertising();
    await _lan.stopAdvertising();
    await _ble.stopAdvertising();
  }

  /// Re-advertise on all enabled transports using the cached identity.
  /// Call this when coming back from off-grid mode.
  Future<void> resumeAdvertising() async {
    if (_myUuid == null) return;
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
      if (_myUuid != null) {
        await _ble.startAdvertising(
          uuid: _myUuid!,
          shortId: _myShortId!,
          displayName: _myDisplayName!,
          statusMessage: _myStatusMessage,
          publicKeyPEM: _myPublicKeyPEM,
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
      if (_myUuid != null) {
        await _lan.startAdvertising(
          uuid: _myUuid!,
          shortId: _myShortId!,
          displayName: _myDisplayName!,
          statusMessage: _myStatusMessage,
          publicKeyPEM: _myPublicKeyPEM,
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
      if (_myUuid != null) {
        await _wifiDirect.startAdvertising(
          uuid: _myUuid!,
          shortId: _myShortId!,
          displayName: _myDisplayName!,
          statusMessage: _myStatusMessage,
          publicKeyPEM: _myPublicKeyPEM,
        );
      }
    } else {
      await _wifiDirect.stopScanning();
      await _wifiDirect.stopAdvertising();
    }
  }

  void _recordTransport(String uuid, TransportMode mode) {
    _peerTransports.putIfAbsent(uuid, () => {}).add(mode);
  }

  void _onPacket(InboundPacket packet) {
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
    final tempTransports = _peerTransports.remove(tempId);
    if (tempTransports != null) {
      _peerTransports.putIfAbsent(canonicalId, () => {}).addAll(tempTransports);
    }
  }

  /// Remove a peer that has gone stale, freeing routing state.
  void removePeer(String peerUuid) {
    _peerTransports.remove(peerUuid);
    // Remove reverse alias entries that pointed to this uuid.
    _peerAliases.removeWhere((_, v) => v == peerUuid);
  }

  /// Returns the best currently available transport for a peer.
  TransportMode currentModeFor(String peerUuid) {
    final canonical = _peerAliases[peerUuid] ?? peerUuid;
    final modes = _peerTransports[canonical];
    if (modes == null || modes.isEmpty) return TransportMode.none;
    if (modes.contains(TransportMode.wifiDirect)) {
      return TransportMode.wifiDirect;
    }
    if (modes.contains(TransportMode.lan)) return TransportMode.lan;
    if (modes.contains(TransportMode.ble)) return TransportMode.ble;
    return TransportMode.none;
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
    final payload = jsonEncode({
      ...data,
      'from': fromUuid,
      'fromShortId': fromShortId,
      'fromName': fromName,
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
