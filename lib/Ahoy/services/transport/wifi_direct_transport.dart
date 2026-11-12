import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants.dart';
import '../../core/enums.dart';
import '../../core/logging.dart';
import '../crypto/crypto_service.dart';
import 'transport_interface.dart';

/// WiFi Direct transport via Android P2P MethodChannel.
/// On iOS and desktop this is a no-op stub.
///
/// Kotlin API surface (channel: 'wifi_direct'):
///   Dart → Kotlin: initialize, discoverPeers, connect {deviceAddress}, sendData {data, recipientIP}, disconnect
///   Kotlin → Dart (via setMethodCallHandler): onPeersDiscovered, onConnectionEstablished, onDataReceived, onConnectionFailed, onDisconnected
class WiFiDirectTransport implements TransportInterface {
  static const _channel = MethodChannel('wifi_direct');
  final int _maxPayloadBytes;
  final CryptoService? _crypto;

  WiFiDirectTransport({
    int maxPayloadBytes = AhoyConstants.wifiDirectMaxPayloadBytes,
    CryptoService? crypto,
    Duration connectAttemptTtl = const Duration(seconds: 30),
    int maxKnownKeys = AhoyConstants.maxTransportKeyEntries,
  }) : _maxPayloadBytes = maxPayloadBytes,
       _crypto = crypto,
       _connectAttemptTtl = connectAttemptTtl,
       _maxKnownKeys = maxKnownKeys;

  @override
  TransportMode get mode => TransportMode.wifiDirect;

  final _packetController = StreamController<InboundPacket>.broadcast();
  final _announcementController =
      StreamController<PeerAnnouncement>.broadcast();

  @override
  Stream<InboundPacket> get packetStream => _packetController.stream;
  @override
  Stream<PeerAnnouncement> get announcementStream =>
      _announcementController.stream;

  // WD device address (MAC) → Ahoy UUID. Populated on first data packet from peer.
  final Map<String, String> _addressToUuid = {};
  // Ahoy UUID → WD device address, for routing sends.
  final Map<String, String> _uuidToAddress = {};
  // Ahoy UUID → public key learned from its first verified identity. A later
  // identity for the same UUID with a different key is refused, so a group
  // member cannot hijack the route of a peer it merely claims to be
  // (audit H-2). Bounded like the routing tables (ninth review N-2).
  final Map<String, String> _uuidKeys = {};
  final int _maxKnownKeys;

  bool _initialized = false;
  bool _isGroupOwner = false;
  String? _groupOwnerAddress;
  Timer? _discoveryTimer;

  // Device addresses with a connect() attempt in flight or recently made.
  // Prevents duplicate connect() calls from repeated onPeersDiscovered
  // events. Entries expire after [_connectAttemptTtl] so a peer whose
  // connect silently failed becomes retryable instead of staying wedged
  // until the next group teardown (review #1/#2).
  final Map<String, DateTime> _connectingAttempts = {};

  // Devices that were auto-connected but never proved they speak Ahoy.
  // Auto-connect gives up after two expired attempts per address per group
  // session, so printers and TVs are not harassed every discovery cycle
  // (audit M-4). A scan restart or a group teardown clears the marks.
  final Set<String> _nonAhoyAddresses = {};
  static const int _maxAutoConnectAttempts = 2;

  /// Expired-attempt counter per address feeding [_nonAhoyAddresses].
  final Map<String, int> _nonAhoyMarkCounts = {};

  // Kotlin's onConnectionFailed does not identify the failed device, so
  // exact bookkeeping is impossible TTL expiry keeps the state honest
  // (review #1).
  final Duration _connectAttemptTtl;

  // Our own identity, cached for broadcasting after connection
  String? _myUuid;
  String? _myShortId;
  String? _myDisplayName;
  String? _myStatusMessage;
  String? _myPublicKeyPEM;

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
    String? announcementSignature,
  }) async {
    if (!Platform.isAndroid) return;
    _myUuid = uuid;
    _myShortId = shortId;
    _myDisplayName = displayName;
    _myStatusMessage = statusMessage;
    _myPublicKeyPEM = publicKeyPEM;

    // Register the handler here as well as in startScanning() so that
    // Kotlin→Dart callbacks (e.g. onDataReceived) are handled regardless of
    // which method is called first.
    _channel.setMethodCallHandler(_onKotlinCall);

    if (!_initialized) {
      try {
        final ok = await _channel.invokeMethod<bool>('initialize') ?? false;
        _initialized = ok;
        if (!ok) ahoyLog('[WiFiDirect] initialize returned false');
      } catch (e) {
        ahoyLog('[WiFiDirect] initialize failed', e);
      }
    }
  }

  @override
  Future<void> stopAdvertising() async {
    // WiFi Direct doesn't have a meaningful "stop advertising" in this model.
    // Disconnect fully removes us from the group.
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      ahoyLog('[WiFiDirect] disconnect failed', e);
    } finally {
      // Reset connection/routing state only keep identity fields (_myUuid etc.)
      // so that _sendIdentity() can still complete a handshake if the OS
      // auto-reconnects, and so startAdvertising() can reinitialise correctly.
      _initialized = false;
      _isGroupOwner = false;
      _groupOwnerAddress = null;
      _connectingAttempts.clear();
      _addressToUuid.clear();
      _uuidToAddress.clear();
      // _uuidKeys deliberately survives teardown: the first-key binding is
      // what stops a post-teardown identity with a different key from
      // re-opening the route-hijack window (sixth review, test gap note).
      // It clears only on dispose or sign-out.
    }
  }

  @override
  Future<void> startScanning() async {
    if (!Platform.isAndroid) return;

    _channel.setMethodCallHandler(_onKotlinCall);

    await _runDiscoverPeers();

    // Android's WiFi Direct discovery times out in ~2 minutes. Restart it
    // periodically so devices that appear later are still found.
    _discoveryTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _runDiscoverPeers(),
    );
  }

  Future<void> _runDiscoverPeers() async {
    try {
      await _channel.invokeMethod('discoverPeers');
    } catch (e) {
      ahoyLog('[WiFiDirect] discoverPeers failed', e);
    }
  }

  @override
  Future<void> stopScanning() async {
    if (!Platform.isAndroid) return;
    // Auto-connect caps reset on a scan restart so pull-to-refresh can retry
    // devices that never proved they speak Ahoy (audit M-4).
    _autoConnectFailuresReset();
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _channel.setMethodCallHandler(null);
    // Don't call disconnect here as it might cause issues when just stopping scanning
    // The disconnect should only be called when completely stopping WiFi Direct
  }

  void _autoConnectFailuresReset() {
    _nonAhoyAddresses.clear();
    _nonAhoyMarkCounts.clear();
  }

  // Receives method calls that Kotlin initiates on us (Kotlin → Dart direction).
  Future<dynamic> _onKotlinCall(MethodCall call) async {
    switch (call.method) {
      case 'onPeersDiscovered':
        _handlePeersDiscovered(call.arguments);
        break;
      case 'onConnectionEstablished':
        _handleConnectionEstablished(call.arguments);
        break;
      case 'onDataReceived':
        _handleDataReceived(call.arguments);
        break;
      case 'onConnectionFailed':
        ahoyLog('[WiFiDirect] connection failed');
        // Kotlin does not identify which device failed guessing from the
        // single pending address removed the wrong peer under concurrency
        // (review #1). The attempt entry expires via TTL instead.
        break;
      case 'onDisconnected':
        _isGroupOwner = false;
        _groupOwnerAddress = null;
        _connectingAttempts.clear();
        _autoConnectFailuresReset();
        ahoyLog('[WiFiDirect] disconnected');
        break;
    }
  }

  void _handlePeersDiscovered(dynamic raw) {
    // raw is List<Map<String, String>> with keys: deviceName, deviceAddress, status
    if (raw == null) return;
    try {
      _pruneConnectingAttempts();
      final peers = (raw as List).cast<Map<Object?, Object?>>();
      for (final p in peers) {
        final address = p['deviceAddress'] as String? ?? '';
        ahoyLog('[WiFiDirect] peer found');

        // Do NOT emit a stub announcement here the peer has no Ahoy identity yet
        // (shortId/UUID unknown) and would show as a duplicate "@" entry in the UI.
        // The real announcement is emitted after TCP identity exchange in _handleDataReceived.

        // Auto-connect to newly found peers if not already connected. Gives
        // up after two expired attempts so non-Ahoy devices stop being
        // contacted on every cycle (audit M-4).
        if (address.isNotEmpty &&
            !_addressToUuid.containsKey(address) &&
            !_connectingAttempts.containsKey(address) &&
            !_nonAhoyAddresses.contains(address)) {
          _connectingAttempts[address] = DateTime.now();
          _tryConnect(address);
        }
      }
    } catch (e) {
      ahoyLog('[WiFiDirect] onPeersDiscovered parse error', e);
    }
  }

  void _handleConnectionEstablished(dynamic raw) {
    if (raw == null) return;
    try {
      final args = Map<String, dynamic>.from(raw as Map);
      _isGroupOwner = args['isGroupOwner'] as bool? ?? false;
      final addr = args['address'] as String? ?? '';
      _groupOwnerAddress = addr.isEmpty ? null : addr;
      // The group formed any in-flight connect attempts are moot; peers
      // outside the group are re-attempted on the next discovery cycle
      // (review #1).
      _connectingAttempts.clear();
      ahoyLog('[WiFiDirect] connected');
      // Group owner waits: connectedClients is empty until the client sends its first
      // TCP packet. The GO replies with its identity when it receives the client's
      // wdIdentity (see _handleDataReceived). Clients send proactively.
      if (!_isGroupOwner) _sendIdentity();
    } catch (e) {
      ahoyLog('[WiFiDirect] onConnectionEstablished parse error', e);
    }
  }

  void _handleDataReceived(dynamic raw) {
    // Kotlin sends: Map { "data": ByteArray, "senderIP": String }
    try {
      List<int> bytes;
      String senderIP = '';

      if (raw is Map) {
        final map = raw as Map<Object?, Object?>;
        final dataRaw = map['data'];
        senderIP = (map['senderIP'] as String?) ?? '';
        bytes = dataRaw is Uint8List
            ? dataRaw
            : Uint8List.fromList((dataRaw as List).cast<int>());
      } else {
        // Fallback for raw bytes (should not occur with current Kotlin code).
        bytes = raw is Uint8List
            ? raw
            : Uint8List.fromList((raw as List).cast<int>());
      }

      if (bytes.isEmpty || bytes.length > _maxPayloadBytes) {
        ahoyLog('[WiFiDirect] rejected invalid payload size');
        return;
      }

      final payload = utf8.decode(bytes);
      final json = jsonDecode(payload) as Map<String, dynamic>;

      if (json['type'] == 'wdIdentity') {
        final uuid = json['uuid'] as String? ?? '';
        if (uuid.isNotEmpty) {
          // Verify the signed identity BEFORE learning routes or announcing
          // the peer wdIdentity packets are otherwise spoofable (audit #5).
          // Fail closed when verification is unavailable.
          final crypto = _crypto;
          if (crypto == null) return;
          final verified = crypto.verifyAnnouncement(
            uuid: uuid,
            shortId: json['shortId'] as String? ?? '',
            displayName: json['displayName'] as String? ?? '',
            statusMessage: json['statusMessage'] as String?,
            publicKeyPEM: json['publicKeyPEM'] as String? ?? '',
            signature: json['signature'] as String? ?? '',
            timestamp: json['timestamp'] as String? ?? '',
          );
          if (!verified ||
              !CryptoService.isFreshTimestamp(
                json['timestamp'] as String?,
              )) {
            ahoyLog('[WiFiDirect] dropping identity that fails verification');
            return;
          }
          // The first verified identity for a UUID fixes its key. A later
          // identity for the same UUID with a different key is refused
          // before any route state changes, so the most recent self-signed
          // claim cannot repoint a peer's traffic (audit H-2).
          final announcedKey = json['publicKeyPEM'] as String? ?? '';
          final knownKey = _uuidKeys[uuid];
          if (knownKey != null && !_sameKey(knownKey, announcedKey)) {
            ahoyLog('[WiFiDirect] dropping identity with a conflicting key');
            return;
          }
          _uuidKeys[uuid] = announcedKey;
          // The key map is bounded like the routing tables (ninth review
          // N-2): a flood of unique verified identities must not grow memory
          // without bound.
          while (_uuidKeys.length > _maxKnownKeys) {
            _uuidKeys.remove(_uuidKeys.keys.first);
          }
          // Group owner: use the actual TCP senderIP to route replies back to client.
          // Client: always route to the group owner's IP.
          final routeIP = _isGroupOwner
              ? (senderIP.isNotEmpty ? senderIP : null)
              : _groupOwnerAddress;
          if (routeIP != null && routeIP.isNotEmpty) {
            _addressToUuid[routeIP] = uuid;
            _uuidToAddress[uuid] = routeIP;
          }
          // Connect-attempt bookkeeping expires via TTL the sender's MAC
          // is not derivable from its IP here, so no targeted removal
          // (review #2).
          _announcementController.add(
            PeerAnnouncement(
              uuid: uuid,
              shortId: json['shortId'] as String? ?? '',
              displayName: json['displayName'] as String? ?? 'Unknown',
              statusMessage: json['statusMessage'] as String?,
              publicKeyPEM: json['publicKeyPEM'] as String?,
              signature: json['signature'] as String?,
              timestamp: json['timestamp'] as String?,
              transport: TransportMode.wifiDirect,
            ),
          );
          // Group owner replies with its own identity so the client learns the GO's UUID.
          // The client connected first, so connectedClients now has the client's IP.
          if (_isGroupOwner && routeIP != null && routeIP.isNotEmpty) {
            _sendIdentityTo(routeIP);
          }
        }
      } else {
        final fromUuid = json['from'] as String? ?? '';
        if (fromUuid.isEmpty) return;
        // Routing is learned only from verified identity exchanges a chat
        // packet claiming an unknown uuid is dropped (audit #5).
        if (!_uuidToAddress.containsKey(fromUuid)) {
          ahoyLog('[WiFiDirect] dropping packet from unknown peer identity');
          return;
        }
        _packetController.add(
          InboundPacket(
            peerUuid: fromUuid,
            peerShortId: json['fromShortId'] as String? ?? '',
            peerDisplayName: json['fromName'] as String? ?? 'Unknown',
            payload: payload,
            transport: TransportMode.wifiDirect,
          ),
        );
      }
    } catch (e) {
      ahoyLog('[WiFiDirect] onDataReceived parse error', e);
    }
  }

  Future<void> _tryConnect(String deviceAddress) async {
    _pruneConnectingAttempts();
    _connectingAttempts[deviceAddress] = DateTime.now();
    try {
      await _channel.invokeMethod('connect', {'deviceAddress': deviceAddress});
    } catch (e) {
      ahoyLog('[WiFiDirect] connect failed', e);
      _connectingAttempts.remove(deviceAddress);
    }
  }

  void _pruneConnectingAttempts() {
    final now = DateTime.now();
    final expired = _connectingAttempts.entries
        .where((entry) => now.difference(entry.value) > _connectAttemptTtl)
        .map((entry) => entry.key)
        .toList();
    for (final address in expired) {
      _connectingAttempts.remove(address);
      // An attempt that expired without the device ever proving it speaks
      // Ahoy counts toward the auto-connect cap (audit M-4). The cap trips
      // after the second expired attempt.
      final attempts = (_nonAhoyMarkCounts[address] ?? 0) + 1;
      _nonAhoyMarkCounts[address] = attempts;
      if (attempts >= _maxAutoConnectAttempts) {
        _nonAhoyAddresses.add(address);
      }
    }
  }

  @visibleForTesting
  int get debugConnectingAttemptCount => _connectingAttempts.length;

  @visibleForTesting
  void debugPruneConnectingAttempts() => _pruneConnectingAttempts();

  @visibleForTesting
  Future<void> debugTryConnect(String deviceAddress) =>
      _tryConnect(deviceAddress);

  void _sendIdentity() {
    if (_myUuid == null) return;
    // Client sends to group owner's IP; group owner passes null so Kotlin
    // broadcasts to all connectedClients.
    _sendIdentityTo(_groupOwnerAddress);
  }

  void _sendIdentityTo(String? recipientIP) {
    if (_myUuid == null) return;
    // Re-sign with a fresh timestamp: receivers reject stale identities
    // (sixth review, findings 1 and 2).
    final crypto = _crypto;
    if (crypto == null || !crypto.isReady) return;
    final timestamp = DateTime.now().toIso8601String();
    final String signature;
    try {
      signature = crypto.signAnnouncement(
        uuid: _myUuid!,
        shortId: _myShortId ?? '',
        displayName: _myDisplayName ?? 'Unknown',
        statusMessage: _myStatusMessage,
        publicKeyPEM: _myPublicKeyPEM,
        timestamp: timestamp,
      );
    } catch (_) {
      return;
    }
    final packet = jsonEncode({
      'type': 'wdIdentity',
      'uuid': _myUuid,
      'shortId': _myShortId ?? '',
      'displayName': _myDisplayName ?? 'Unknown',
      'statusMessage': _myStatusMessage,
      'publicKeyPEM': _myPublicKeyPEM,
      'signature': signature,
      'timestamp': timestamp,
    });
    _sendBytes(utf8.encode(packet), recipientIP);
  }

  @override
  Future<bool> send(String peerUuid, String payload) async {
    if (!Platform.isAndroid) return false;
    final address = _uuidToAddress[peerUuid] ?? _groupOwnerAddress;
    if (address == null || address.isEmpty) {
      ahoyLog('[WiFiDirect] send has no route yet');
      return false;
    }
    return _sendBytes(utf8.encode(payload), address);
  }

  Future<bool> _sendBytes(List<int> bytes, String? recipientIP) async {
    if (bytes.isEmpty || bytes.length > _maxPayloadBytes) {
      ahoyLog('[WiFiDirect] refusing invalid payload size');
      return false;
    }

    try {
      final args = <String, dynamic>{'data': Uint8List.fromList(bytes)};
      if (recipientIP != null) {
        args['recipientIP'] = recipientIP;
      }
      final result = await _channel.invokeMethod<bool>('sendData', args);
      return result ?? false;
    } catch (e) {
      ahoyLog('[WiFiDirect] sendData failed', e);
      return false;
    }
  }

  @visibleForTesting
  void debugHandleDataReceived(dynamic raw) => _handleDataReceived(raw);

  @visibleForTesting
  void debugHandlePeersDiscovered(dynamic raw) => _handlePeersDiscovered(raw);

  @visibleForTesting
  void debugOnDisconnected() =>
      _onKotlinCall(const MethodCall('onDisconnected'));

  @visibleForTesting
  bool get debugIsNonAhoyAddress => _nonAhoyAddresses.isNotEmpty;

  @visibleForTesting
  void debugHandleConnectionEstablished(dynamic raw) =>
      _handleConnectionEstablished(raw);

  @visibleForTesting
  Map<String, String> get debugUuidToAddress => Map.unmodifiable(_uuidToAddress);

  @visibleForTesting
  Map<String, String> get debugUuidKeys => Map.unmodifiable(_uuidKeys);

  /// Whitespace-insensitive PEM comparison, matching the other layers.
  static bool _sameKey(String a, String b) {
    final ws = RegExp(r'\s+');
    return a.replaceAll(ws, '') == b.replaceAll(ws, '');
  }

  @visibleForTesting
  Future<bool> debugSendBytes(List<int> bytes, {String? recipientIP}) {
    return _sendBytes(bytes, recipientIP);
  }

  @override
  Future<void> dispose() async {
    // Tear down the native group and server socket too stopScanning only
    // stops discovery, so without this the group and server socket stay
    // alive after disposal (review #3).
    await stopAdvertising();
    await stopScanning();
    _myUuid = null;
    _myShortId = null;
    _myDisplayName = null;
    _myStatusMessage = null;
    _myPublicKeyPEM = null;
    _packetController.close();
    _announcementController.close();
  }
}
