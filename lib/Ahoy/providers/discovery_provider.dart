import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/enums.dart';
import '../core/logging.dart';
import '../models/nearby_peer.dart';
import '../services/discovery/discovery_service.dart';
import '../services/transport_manager.dart';
import '../services/transport/transport_interface.dart';
import '../services/storage/prefs_store.dart';
import '../core/constants.dart';
import '../services/crypto/crypto_service.dart';

class DiscoveryProvider extends ChangeNotifier {
  final DiscoveryService _discovery;
  final TransportManager _transport;
  final PrefsStore _prefs;
  final CryptoService _crypto;

  List<NearbyPeer> _peers = [];
  bool _offGrid = false;
  bool _receiveOff = false;
  bool _bleEnabled = true;
  bool _lanEnabled = true;
  bool _wifiDirectEnabled = true;

  /// Human-readable transport problems (missing permissions) found at
  /// startup, surfaced on the Discover screen with an open-settings action
  /// (UI review #6). Empty when everything is granted.
  List<String> _permissionProblems = const [];
  List<String> get permissionProblems =>
      List.unmodifiable(_permissionProblems);

  /// Called by the permission flow after each cold-start request.
  void setPermissionProblems(List<String> problems) {
    _permissionProblems = List.of(problems);
    notifyListeners();
  }

  /// Test-only: cancels the periodic peer-cleanup timer so widget tests that
  /// build this provider do not leave timers pending (fake async).
  @visibleForTesting
  void debugStopCleanupTimer() => _discovery.stopCleanupTimer();

  StreamSubscription? _sub;

  List<NearbyPeer> get peers => _peers;
  bool get offGrid => _offGrid;
  bool get receiveOff => _receiveOff;
  bool get bleEnabled => _bleEnabled;
  bool get lanEnabled => _lanEnabled;
  bool get wifiDirectEnabled => _wifiDirectEnabled;

  final Set<String> blockedUuids = {};

  /// Invoked with (uuid, pem) for every accepted announcement that carried a
  /// public key wired to ChatService so first contacts pin to the
  /// discovery-verified key (audit #7).
  void Function(String uuid, String pem)? onVerifiedKey;

  DiscoveryProvider(this._discovery, this._transport, this._prefs, this._crypto) {
    _offGrid = _prefs.getBool(AhoyConstants.prefOffGrid);
    _receiveOff = _prefs.getBool(AhoyConstants.prefReceiveOff);
    _bleEnabled = _prefs.getBool(
      AhoyConstants.prefBleEnabled,
      defaultValue: true,
    );
    _lanEnabled = _prefs.getBool(
      AhoyConstants.prefLanEnabled,
      defaultValue: true,
    );
    _wifiDirectEnabled = _prefs.getBool(
      AhoyConstants.prefWifiDirectEnabled,
      defaultValue: true,
    );

    _loadBlockedUuids();

    _sub = _discovery.peerStream.listen((peers) {
      _peers = peers;
      notifyListeners();
    });

    // When stale peers are cleaned up, remove their routing state from TransportManager.
    _discovery.startCleanupTimer(
      onRemoved: (removed) {
        for (final uuid in removed) {
          _transport.removePeer(uuid);
        }
      },
    );
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
    await _prefs.setString(
      AhoyConstants.prefBlockedUuids,
      jsonEncode(blockedUuids.toList()),
    );
  }

  void onAnnouncement(PeerAnnouncement announcement) {
    if (!_acceptAnnouncement(announcement)) return;
    final alias = _discovery.onAnnouncement(announcement, blockedUuids);
    if (alias != null) {
      // A temporary identifier (BT/WFD MAC) was resolved to a canonical Ahoy UUID.
      // Tell TransportManager so it routes sends/receives correctly.
      _transport.registerAlias(
        tempId: alias.tempId,
        canonicalId: alias.canonicalId,
      );
    }
    // The key handed to chat must be the one DiscoveryService actually kept.
    // A later announcement claiming the same UUID with a different key is
    // refused there, so the chat layer must never observe the refused key
    // (audit H-2). This used to run before the veto, which let a forged
    // self-signed announcement poison first-contact pinning.
    final canonicalUuid = alias?.canonicalId ?? announcement.uuid;
    final acceptedPeer = _discovery.peer(canonicalUuid);
    final key = acceptedPeer?.publicKeyPEM;
    if (key != null && key.isNotEmpty) {
      onVerifiedKey?.call(acceptedPeer!.uuid, key);
    }
  }

  /// Identity-binding policy (audit H-2):
  /// 1. shortId is deterministically derived from the UUID any announcement
  ///    whose shortId does not match its claimed UUID is forged and dropped.
  /// 2. Announcements carrying a public key must carry a valid RSA-SHA256
  ///    signature made with that key, binding the key to the claimed identity.
  /// 3. BLE scan-response announcements (uuid = BT MAC, no key) are accepted
  ///    for display only; identity is bound at the first signed chat message.
  bool _acceptAnnouncement(PeerAnnouncement announcement) {
    final isRealUuid = CryptoService.isRealAhoyUuid(announcement.uuid);
    if (isRealUuid &&
        announcement.shortId.isNotEmpty &&
        announcement.shortId.toUpperCase() !=
            CryptoService.shortIdFromUuid(announcement.uuid)) {
      ahoyLog('[Discovery] dropping announcement with mismatched shortId');
      return false;
    }
    if (announcement.publicKeyPEM == null) {
      // Keyless announcements are only legitimate from BLE scan responses —
      // LAN and WiFi Direct must carry a signed key (audit #5).
      return announcement.transport == TransportMode.ble;
    }
    final signature = announcement.signature;
    if (signature == null || signature.isEmpty) {
      ahoyLog('[Discovery] dropping keyed announcement without signature');
      return false;
    }
    // Freshness: a replayed announcement must not keep a departed peer
    // online or repoint routing (sixth review, findings 1 and 2).
    if (!CryptoService.isFreshTimestamp(announcement.timestamp)) {
      ahoyLog('[Discovery] dropping stale announcement');
      return false;
    }
    final ok = _crypto.verifyAnnouncement(
      uuid: announcement.uuid,
      shortId: announcement.shortId,
      displayName: announcement.displayName,
      statusMessage: announcement.statusMessage,
      publicKeyPEM: announcement.publicKeyPEM!,
      signature: signature,
      timestamp: announcement.timestamp!,
    );
    if (!ok) {
      ahoyLog('[Discovery] dropping announcement with invalid signature');
    }
    return ok;
  }

  Future<void> setOffGrid(bool value) async {
    _offGrid = value;
    await _prefs.setBool(AhoyConstants.prefOffGrid, value: value);
    // The flag lives in TransportManager so every advertise path is gated in
    // one place (audit H-3). Turning it off resumes broadcasting; turning it
    // on stops advertising inside the manager.
    await _transport.setOffGrid(value);
    if (!value) {
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

  /// Clears all per-session discovery state (called on sign-out, audit #3).
  void reset() {
    blockedUuids.clear();
    onVerifiedKey = null;
    _discovery.clearAll();
    _peers = [];
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
    // Restart discovery without the off/on toggle: toggling a transport off
    // tears down its live state — for WiFi Direct the settings toggle calls
    // stopAdvertising, which removes the group and drops active chats
    // (UI review #4). Scanning alone restarts here.
    await _transport.restartScanning();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _discovery.dispose();
    super.dispose();
  }
}
