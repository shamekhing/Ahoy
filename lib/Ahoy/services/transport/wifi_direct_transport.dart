import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/enums.dart';
import 'transport_interface.dart';

/// WiFi Direct transport via Android P2P MethodChannel.
/// On iOS and desktop this is a no-op stub.
///
/// Kotlin API surface (channel: 'wifi_direct'):
///   Dart → Kotlin: initialize, discoverPeers, connect {deviceAddress}, sendData {data, recipientIP}, disconnect
///   Kotlin → Dart (via setMethodCallHandler): onPeersDiscovered, onConnectionEstablished, onDataReceived, onConnectionFailed, onDisconnected
class WiFiDirectTransport implements TransportInterface {
  static const _channel = MethodChannel('wifi_direct');

  @override
  TransportMode get mode => TransportMode.wifiDirect;

  final _packetController = StreamController<InboundPacket>.broadcast();
  final _announcementController = StreamController<PeerAnnouncement>.broadcast();

  @override
  Stream<InboundPacket> get packetStream => _packetController.stream;
  @override
  Stream<PeerAnnouncement> get announcementStream => _announcementController.stream;

  // WD device address (MAC) → Ahoy UUID. Populated on first data packet from peer.
  final Map<String, String> _addressToUuid = {};
  // Ahoy UUID → WD device address, for routing sends.
  final Map<String, String> _uuidToAddress = {};

  bool _initialized = false;
  bool _isGroupOwner = false;
  String? _groupOwnerAddress;

  // Our own identity, cached for broadcasting after connection
  String? _myUuid;
  String? _myShortId;
  String? _myDisplayName;
  String? _myStatusMessage;

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  }) async {
    if (!Platform.isAndroid) return;
    _myUuid = uuid;
    _myShortId = shortId;
    _myDisplayName = displayName;
    _myStatusMessage = statusMessage;

    if (!_initialized) {
      try {
        final ok = await _channel.invokeMethod<bool>('initialize') ?? false;
        _initialized = ok;
        if (!ok) debugPrint('[WiFiDirect] initialize returned false');
      } catch (e) {
        debugPrint('[WiFiDirect] initialize failed: $e');
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
      debugPrint('[WiFiDirect] disconnect failed: $e');
    }
  }

  @override
  Future<void> startScanning() async {
    if (!Platform.isAndroid) return;

    // Register handler for Kotlin → Dart callbacks.
    _channel.setMethodCallHandler(_onKotlinCall);

    try {
      await _channel.invokeMethod('discoverPeers');
    } catch (e) {
      debugPrint('[WiFiDirect] discoverPeers failed: $e');
    }
  }

  @override
  Future<void> stopScanning() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      debugPrint('[WiFiDirect] stopScanning/disconnect failed: $e');
    }
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
        debugPrint('[WiFiDirect] Connection failed: ${call.arguments}');
        break;
      case 'onDisconnected':
        _isGroupOwner = false;
        _groupOwnerAddress = null;
        debugPrint('[WiFiDirect] Disconnected');
        break;
    }
  }

  void _handlePeersDiscovered(dynamic raw) {
    // raw is List<Map<String, String>> with keys: deviceName, deviceAddress, status
    if (raw == null) return;
    try {
      final peers = (raw as List).cast<Map<Object?, Object?>>();
      for (final p in peers) {
        final name = p['deviceName'] as String? ?? 'Unknown';
        final address = p['deviceAddress'] as String? ?? '';
        debugPrint('[WiFiDirect] Peer found: $name @ $address');
        // We don't emit a PeerAnnouncement yet — we don't have an Ahoy UUID.
        // Identity is exchanged on the first data packet (see _handleDataReceived).
        // Auto-connect to newly found peers if not already connected.
        if (address.isNotEmpty && !_uuidToAddress.containsValue(address)) {
          _tryConnect(address);
        }
      }
    } catch (e) {
      debugPrint('[WiFiDirect] onPeersDiscovered parse error: $e');
    }
  }

  void _handleConnectionEstablished(dynamic raw) {
    if (raw == null) return;
    try {
      final args = Map<String, dynamic>.from(raw as Map);
      _isGroupOwner = args['isGroupOwner'] as bool? ?? false;
      final addr = args['address'] as String? ?? '';
      // Group owner: addr is empty → null, so cmdSendData broadcasts to all clients.
      // Client: addr is the group owner's IP used for outbound routing.
      _groupOwnerAddress = addr.isEmpty ? null : addr;
      debugPrint('[WiFiDirect] Connected. GroupOwner=$_isGroupOwner addr=$_groupOwnerAddress');
      _sendIdentity();
    } catch (e) {
      debugPrint('[WiFiDirect] onConnectionEstablished parse error: $e');
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
        bytes = raw is Uint8List ? raw : Uint8List.fromList((raw as List).cast<int>());
      }

      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      if (json['type'] == 'wdIdentity') {
        final uuid = json['uuid'] as String? ?? '';
        if (uuid.isNotEmpty) {
          // Group owner: use the actual TCP senderIP to route replies back to client.
          // Client: always route to the group owner's IP.
          final routeIP = _isGroupOwner
              ? (senderIP.isNotEmpty ? senderIP : null)
              : _groupOwnerAddress;
          if (routeIP != null && routeIP.isNotEmpty) {
            _addressToUuid[routeIP] = uuid;
            _uuidToAddress[uuid] = routeIP;
          }
          _announcementController.add(PeerAnnouncement(
            uuid: uuid,
            shortId: json['shortId'] as String? ?? '',
            displayName: json['displayName'] as String? ?? 'Unknown',
            statusMessage: json['statusMessage'] as String?,
            transport: TransportMode.wifiDirect,
          ));
        }
      } else {
        final fromUuid = json['from'] as String? ?? '';
        if (fromUuid.isEmpty) return;
        // Learn the routing IP from senderIP on first message.
        if (!_uuidToAddress.containsKey(fromUuid)) {
          final routeIP = _isGroupOwner
              ? (senderIP.isNotEmpty ? senderIP : null)
              : _groupOwnerAddress;
          if (routeIP != null && routeIP.isNotEmpty) {
            _uuidToAddress[fromUuid] = routeIP;
            _addressToUuid[routeIP] = fromUuid;
          }
        }
        _packetController.add(InboundPacket(
          peerUuid: fromUuid,
          peerShortId: json['fromShortId'] as String? ?? '',
          peerDisplayName: json['fromName'] as String? ?? 'Unknown',
          payload: utf8.decode(bytes),
          transport: TransportMode.wifiDirect,
        ));
      }
    } catch (e) {
      debugPrint('[WiFiDirect] onDataReceived parse error: $e');
    }
  }

  Future<void> _tryConnect(String deviceAddress) async {
    try {
      await _channel.invokeMethod('connect', {'deviceAddress': deviceAddress});
    } catch (e) {
      debugPrint('[WiFiDirect] connect to $deviceAddress failed: $e');
    }
  }

  void _sendIdentity() {
    if (_myUuid == null) return;
    final packet = jsonEncode({
      'type': 'wdIdentity',
      'uuid': _myUuid,
      'shortId': _myShortId ?? '',
      'displayName': _myDisplayName ?? 'Unknown',
      'statusMessage': _myStatusMessage,
    });
    // Client sends to group owner's IP; group owner passes null so Kotlin
    // broadcasts to all connectedClients.
    _sendBytes(utf8.encode(packet), _groupOwnerAddress);
  }

  @override
  Future<bool> send(String peerUuid, String payload) async {
    if (!Platform.isAndroid) return false;
    final address = _uuidToAddress[peerUuid] ?? _groupOwnerAddress;
    return _sendBytes(utf8.encode(payload), address);
  }

  Future<bool> _sendBytes(List<int> bytes, String? recipientIP) async {
    try {
      final result = await _channel.invokeMethod<bool>('sendData', {
        'data': Uint8List.fromList(bytes),
        if (recipientIP != null) 'recipientIP': recipientIP,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('[WiFiDirect] sendData failed: $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    await stopScanning();
    _packetController.close();
    _announcementController.close();
  }
}
