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
  final _announcementController = StreamController<PeerAnnouncement>.broadcast();

  Stream<InboundPacket> get packetStream => _packetController.stream;
  Stream<PeerAnnouncement> get announcementStream => _announcementController.stream;

  final List<StreamSubscription> _subs = [];

  bool _bleEnabled = true;
  bool _lanEnabled = true;
  bool _wifiDirectEnabled = true;

  // Track which transports have seen each peer for live mode resolution
  final Map<String, Set<TransportMode>> _peerTransports = {};

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

    // Wire packet streams
    _subs.add(_wifiDirect.packetStream.listen(_onPacket));
    _subs.add(_lan.packetStream.listen(_onPacket));
    _subs.add(_ble.packetStream.listen(_onPacket));

    // Wire announcement streams — tag with transport priority
    _subs.add(_wifiDirect.announcementStream.listen((a) {
      _peerTransports.putIfAbsent(a.uuid, () => {}).add(TransportMode.wifiDirect);
      _announcementController.add(a);
    }));
    _subs.add(_lan.announcementStream.listen((a) {
      _peerTransports.putIfAbsent(a.uuid, () => {}).add(TransportMode.lan);
      _announcementController.add(a);
    }));
    _subs.add(_ble.announcementStream.listen((a) {
      _peerTransports.putIfAbsent(a.uuid, () => {}).add(TransportMode.ble);
      _announcementController.add(a);
    }));

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
          uuid: uuid, shortId: shortId, displayName: displayName, statusMessage: statusMessage, publicKeyPEM: publicKeyPEM);
    }
    if (_lanEnabled) {
      await _lan.startAdvertising(
          uuid: uuid, shortId: shortId, displayName: displayName, statusMessage: statusMessage, publicKeyPEM: publicKeyPEM);
    }
    if (_bleEnabled) {
      await _ble.startAdvertising(
          uuid: uuid, shortId: shortId, displayName: displayName, statusMessage: statusMessage, publicKeyPEM: publicKeyPEM);
    }
  }

  Future<void> stopAdvertising() async {
    await _wifiDirect.stopAdvertising();
    await _lan.stopAdvertising();
    await _ble.stopAdvertising();
  }

  Future<void> setBleEnabled(bool enabled) async {
    _bleEnabled = enabled;
    if (enabled) {
      await _ble.startScanning();
    } else {
      await _ble.stopScanning();
      await _ble.stopAdvertising();
    }
  }

  Future<void> setLanEnabled(bool enabled) async {
    _lanEnabled = enabled;
    if (enabled) {
      await _lan.startScanning();
    } else {
      await _lan.stopScanning();
      await _lan.stopAdvertising();
    }
  }

  Future<void> setWifiDirectEnabled(bool enabled) async {
    _wifiDirectEnabled = enabled;
    if (enabled) {
      await _wifiDirect.startScanning();
    } else {
      await _wifiDirect.stopScanning();
      await _wifiDirect.stopAdvertising();
    }
  }

  void _onPacket(InboundPacket packet) {
    _peerTransports.putIfAbsent(packet.peerUuid, () => {}).add(packet.transport);
    _packetController.add(packet);
  }

  /// Returns the best currently available transport for a peer.
  /// Computed live — never cached.
  TransportMode currentModeFor(String peerUuid) {
    final modes = _peerTransports[peerUuid];
    if (modes == null || modes.isEmpty) return TransportMode.none;
    if (modes.contains(TransportMode.wifiDirect)) return TransportMode.wifiDirect;
    if (modes.contains(TransportMode.lan)) return TransportMode.lan;
    if (modes.contains(TransportMode.ble)) return TransportMode.ble;
    return TransportMode.none;
  }

  /// Send payload to peer, selecting the best available transport.
  Future<bool> send(String peerUuid, String fromUuid, String fromShortId, String fromName, Map<String, dynamic> data) async {
    final payload = jsonEncode({...data, 'from': fromUuid, 'fromShortId': fromShortId, 'fromName': fromName});
    final mode = currentModeFor(peerUuid);
    switch (mode) {
      case TransportMode.wifiDirect:
        return _wifiDirect.send(peerUuid, payload);
      case TransportMode.lan:
        return _lan.send(peerUuid, payload);
      case TransportMode.ble:
        return _ble.send(peerUuid, payload);
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
