import 'dart:async';
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

    _sub = _discovery.peerStream.listen((peers) {
      _peers = peers;
      notifyListeners();
    });
    _discovery.startCleanupTimer();
  }

  void onAnnouncement(PeerAnnouncement announcement) {
    _discovery.onAnnouncement(announcement, blockedUuids);
  }

  Future<void> setOffGrid(bool value) async {
    _offGrid = value;
    await _prefs.setBool(AhoyConstants.prefOffGrid, value: value);
    if (value) {
      await _transport.stopAdvertising();
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
    notifyListeners();
  }

  void unblockPeer(String uuid) {
    blockedUuids.remove(uuid);
    _discovery.updateBlockedStatus(uuid, false);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _discovery.dispose();
    super.dispose();
  }
}
