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
  }) : _maxPayloadBytes = maxPayloadBytes,
       _crypto = crypto;

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

  bool _initialized = false;
  bool _isGroupOwner = false;
  String? _groupOwnerAddress;
  Timer? _discoveryTimer;

  // Addresses for which a connect() call is already in flight or succeeded.
  // Prevents duplicate connect() calls from repeated onPeersDiscovered events.
  final _connectingAddresses = <String>{};

  // The single device address whose connect() call is currently in flight.
  // WiFi Direct only allows one pending group-formation attempt at a time.
  String? _pendingConnectAddress;

  // Our own identity, cached for broadcasting after connection
  String? _myUuid;
  String? _myShortId;
  String? _myDisplayName;
  String? _myStatusMessage;
  String? _myPublicKeyPEM;
  String? _myAnnouncementSignature;

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
    _myAnnouncementSignature = announcementSignature;

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
      // Reset connection/routing state only — keep identity fields (_myUuid etc.)
      // so that _sendIdentity() can still complete a handshake if the OS
      // auto-reconnects, and so startAdvertising() can reinitialise correctly.
      _initialized = false;
      _isGroupOwner = false;
      _groupOwnerAddress = null;
      _connectingAddresses.clear();
      _pendingConnectAddress = null;
      _addressToUuid.clear();
      _uuidToAddress.clear();
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
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _channel.setMethodCallHandler(null);
    // Don't call disconnect here as it might cause issues when just stopping scanning
    // The disconnect should only be called when completely stopping WiFi Direct
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
        // Release only the address whose connect() just failed so that other
        // in-flight or already-established connections are not disturbed.
        if (_pendingConnectAddress != null) {
          _connectingAddresses.remove(_pendingConnectAddress);
          _pendingConnectAddress = null;
        }
        break;
      case 'onDisconnected':
        _isGroupOwner = false;
        _groupOwnerAddress = null;
        _connectingAddresses.clear();
        ahoyLog('[WiFiDirect] disconnected');
        break;
    }
  }

  void _handlePeersDiscovered(dynamic raw) {
    // raw is List<Map<String, String>> with keys: deviceName, deviceAddress, status
    if (raw == null) return;
    try {
      final peers = (raw as List).cast<Map<Object?, Object?>>();
      for (final p in peers) {
        final address = p['deviceAddress'] as String? ?? '';
        ahoyLog('[WiFiDirect] peer found');

        // Do NOT emit a stub announcement here — the peer has no Ahoy identity yet
        // (shortId/UUID unknown) and would show as a duplicate "@" entry in the UI.
        // The real announcement is emitted after TCP identity exchange in _handleDataReceived.

        // Auto-connect to newly found peers if not already connected.
        if (address.isNotEmpty &&
            !_addressToUuid.containsKey(address) &&
            !_connectingAddresses.contains(address)) {
          _connectingAddresses.add(address);
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
          // the peer — wdIdentity packets are otherwise spoofable (audit #5).
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
          );
          if (!verified) {
            ahoyLog('[WiFiDirect] dropping identity that fails verification');
            return;
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
          // Address is now mapped to a UUID — no longer needs to be in the
          // connecting set. Leaving it in would block reconnect after a failed
          // identity exchange (socket closed before write completed).
          _connectingAddresses.remove(
            _isGroupOwner ? senderIP : _groupOwnerAddress,
          );
          _announcementController.add(
            PeerAnnouncement(
              uuid: uuid,
              shortId: json['shortId'] as String? ?? '',
              displayName: json['displayName'] as String? ?? 'Unknown',
              statusMessage: json['statusMessage'] as String?,
              publicKeyPEM: json['publicKeyPEM'] as String?,
              signature: json['signature'] as String?,
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
        // Routing is learned only from verified identity exchanges — a chat
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
    _pendingConnectAddress = deviceAddress;
    try {
      await _channel.invokeMethod('connect', {'deviceAddress': deviceAddress});
    } catch (e) {
      ahoyLog('[WiFiDirect] connect failed', e);
      _connectingAddresses.remove(deviceAddress);
      if (_pendingConnectAddress == deviceAddress) {
        _pendingConnectAddress = null;
      }
    }
  }

  void _sendIdentity() {
    if (_myUuid == null) return;
    // Client sends to group owner's IP; group owner passes null so Kotlin
    // broadcasts to all connectedClients.
    _sendIdentityTo(_groupOwnerAddress);
  }

  void _sendIdentityTo(String? recipientIP) {
    if (_myUuid == null) return;
    final packet = jsonEncode({
      'type': 'wdIdentity',
      'uuid': _myUuid,
      'shortId': _myShortId ?? '',
      'displayName': _myDisplayName ?? 'Unknown',
      'statusMessage': _myStatusMessage,
      'publicKeyPEM': _myPublicKeyPEM,
      'signature': _myAnnouncementSignature,
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
  Future<bool> debugSendBytes(List<int> bytes, {String? recipientIP}) {
    return _sendBytes(bytes, recipientIP);
  }

  @override
  Future<void> dispose() async {
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
