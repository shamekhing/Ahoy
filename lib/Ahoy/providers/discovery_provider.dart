import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/nearby_peer.dart';
import '../services/discovery/discovery_service.dart';
import '../services/transport_manager.dart';
import '../services/transport/transport_interface.dart';
import '../services/storage/prefs_store.dart';
import '../core/constants.dart';

class DiscoveryProvider extends ChangeNotifier {
  final DiscoveryService _discovery;
  final TransportManager _transport;
  final PrefsStore _prefs;

  List<NearbyPeer> _peers = [];
  bool _offGrid = false;
  bool _receiveOff = false;
  bool _bleEnabled = true;
  bool _lanEnabled = true;
  bool _wifiDirectEnabled = true;

  StreamSubscription? _sub;

  List<NearbyPeer> get peers => _peers;
  bool get offGrid => _offGrid;
  bool get receiveOff => _receiveOff;
  bool get bleEnabled => _bleEnabled;
  bool get lanEnabled => _lanEnabled;
  bool get wifiDirectEnabled => _wifiDirectEnabled;

  final Set<String> blockedUuids = {};

  DiscoveryProvider(this._discovery, this._transport, this._prefs) {
    _offGrid = _prefs.getBool(AhoyConstants.prefOffGrid);
    _receiveOff = _prefs.getBool(AhoyConstants.prefReceiveOff);
    _bleEnabled = _prefs.getBool(AhoyConstants.prefBleEnabled, defaultValue: true);
    _lanEnabled = _prefs.getBool(AhoyConstants.prefLanEnabled, defaultValue: true);
    _wifiDirectEnabled = _prefs.getBool(AhoyConstants.prefWifiDirectEnabled, defaultValue: true);

    _loadBlockedUuids();

    _sub = _discovery.peerStream.listen((peers) {
      _peers = peers;
      notifyListeners();
    });

    // When stale peers are cleaned up, remove their routing state from TransportManager.
    _discovery.startCleanupTimer(onRemoved: (removed) {
      for (final uuid in removed) {
        _transport.removePeer(uuid);
      }
    });
  }

  void _loadBlockedUuids() {
    try {
      final raw = _prefs.getString(AhoyConstants.prefBlockedUuids);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        blockedUuids.addAll(list.cast<String>());
      }
    } catch (_) {}
  }

  Future<void> _saveBlockedUuids() async {
    await _prefs.setString(AhoyConstants.prefBlockedUuids, jsonEncode(blockedUuids.toList()));
  }

  void onAnnouncement(PeerAnnouncement announcement) {
    final alias = _discovery.onAnnouncement(announcement, blockedUuids);
    if (alias != null) {
      // A temporary identifier (BT/WFD MAC) was resolved to a canonical Ahoy UUID.
      // Tell TransportManager so it routes sends/receives correctly.
      _transport.registerAlias(tempId: alias.tempId, canonicalId: alias.canonicalId);
    }
  }

  Future<void> setOffGrid(bool value) async {
    _offGrid = value;
    await _prefs.setBool(AhoyConstants.prefOffGrid, value: value);
    if (value) {
      await _transport.stopAdvertising();
    } else {
      await _transport.resumeAdvertising();
    }
    notifyListeners();
  }

  Future<void> setReceiveOff(bool value) async {
    _receiveOff = value;
    await _prefs.setBool(AhoyConstants.prefReceiveOff, value: value);
    notifyListeners();
  }

  Future<void> setBleEnabled(bool value) async {
    _bleEnabled = value;
    await _prefs.setBool(AhoyConstants.prefBleEnabled, value: value);
    await _transport.setBleEnabled(value);
    notifyListeners();
  }

  Future<void> setLanEnabled(bool value) async {
    _lanEnabled = value;
    await _prefs.setBool(AhoyConstants.prefLanEnabled, value: value);
    await _transport.setLanEnabled(value);
    notifyListeners();
  }

  Future<void> setWifiDirectEnabled(bool value) async {
    _wifiDirectEnabled = value;
    await _prefs.setBool(AhoyConstants.prefWifiDirectEnabled, value: value);
    await _transport.setWifiDirectEnabled(value);
    notifyListeners();
  }

  void blockPeer(String uuid) {
    blockedUuids.add(uuid);
    _discovery.updateBlockedStatus(uuid, true);
    _saveBlockedUuids();
    notifyListeners();
  }

  void unblockPeer(String uuid) {
    blockedUuids.remove(uuid);
    _discovery.updateBlockedStatus(uuid, false);
    _saveBlockedUuids();
    notifyListeners();
  }

  Future<void> refreshPeers() async {
    // Snapshot flags before toggling — use the provider's own setters so
    // _bleEnabled/_lanEnabled/_wifiDirectEnabled and prefs stay consistent.
    final ble = _bleEnabled;
    final lan = _lanEnabled;
    final wd = _wifiDirectEnabled;
    if (ble) await setBleEnabled(false);
    if (lan) await setLanEnabled(false);
    if (wd) await setWifiDirectEnabled(false);
    if (ble) await setBleEnabled(true);
    if (lan) await setLanEnabled(true);
    if (wd) await setWifiDirectEnabled(true);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _discovery.dispose();
    super.dispose();
  }
}
