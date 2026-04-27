import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../core/enums.dart';
import 'transport_interface.dart';

class LanTransport implements TransportInterface {
  @override
  TransportMode get mode => TransportMode.lan;

  final _packetController = StreamController<InboundPacket>.broadcast();
  final _announcementController = StreamController<PeerAnnouncement>.broadcast();

  @override
  Stream<InboundPacket> get packetStream => _packetController.stream;
  @override
  Stream<PeerAnnouncement> get announcementStream => _announcementController.stream;

  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  Timer? _broadcastTimer;
  bool _advertising = false;

  String? _myUuid;
  String? _myShortId;
  String? _myDisplayName;
  String? _myStatusMessage;
  String? _myPublicKeyPEM;

  // peerUuid → InternetAddress + port for TCP
  final Map<String, _PeerConn> _peerConns = {};

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  }) async {
    _myUuid = uuid;
    _myShortId = shortId;
    _myDisplayName = displayName;
    _myStatusMessage = statusMessage;
    _myPublicKeyPEM = publicKeyPEM;
    _advertising = true;
    _startBroadcastTimer();
  }

  @override
  Future<void> stopAdvertising() async {
    _advertising = false;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
  }

  @override
  Future<void> startScanning() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, AhoyConstants.lanDiscoveryPort);
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen(_onUdpDatagram, onError: (e) => debugPrint('[LAN] UDP socket error: $e'));
    } catch (e) {
      debugPrint('[LAN] UDP bind failed: $e');
    }

    try {
      _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, AhoyConstants.lanMessagingPort);
      _tcpServer!.listen(_onTcpConnection);
    } catch (e) {
      debugPrint('[LAN] TCP server bind failed: $e');
    }
  }

  @override
  Future<void> stopScanning() async {
    _udpSocket?.close();
    _udpSocket = null;
    _tcpServer?.close();
    _tcpServer = null;
  }

  void _startBroadcastTimer() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: AhoyConstants.lanBroadcastIntervalSeconds),
      (_) => _broadcast(),
    );
    _broadcast();
  }

  Future<void> _broadcast() async {
    if (!_advertising || _myUuid == null) return;
    try {
      final data = utf8.encode(jsonEncode({
        'type': 'ahoy_announce',
        'uuid': _myUuid,
        'shortId': _myShortId,
        'displayName': _myDisplayName,
        'statusMessage': _myStatusMessage,
        'publicKeyPEM': _myPublicKeyPEM,
        'port': AhoyConstants.lanMessagingPort,
      }));

      // Collect broadcast targets: the limited broadcast + each interface's
      // directed /24 subnet broadcast (more reliable when AP isolation is on).
      final targets = <String>{'255.255.255.255'};
      try {
        final ifaces = await NetworkInterface.list(
          includeLoopback: false,
          type: InternetAddressType.IPv4,
        );
        for (final iface in ifaces) {
          for (final addr in iface.addresses) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
            }
          }
        }
      } catch (_) {}

      for (final target in targets) {
        try {
          final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
          socket.broadcastEnabled = true;
          socket.send(data, InternetAddress(target), AhoyConstants.lanDiscoveryPort);
          socket.close();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[LAN] Broadcast failed: $e');
    }
  }

  void _onUdpDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udpSocket?.receive();
    if (dg == null) return;
    try {
      final json = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (json['type'] != 'ahoy_announce') return;
      final uuid = json['uuid'] as String?;
      if (uuid == null || uuid == _myUuid) return;

      _peerConns[uuid] = _PeerConn(dg.address, AhoyConstants.lanMessagingPort);

      _announcementController.add(PeerAnnouncement(
        uuid: uuid,
        shortId: json['shortId'] as String? ?? '',
        displayName: json['displayName'] as String? ?? 'Unknown',
        statusMessage: json['statusMessage'] as String?,
        publicKeyPEM: json['publicKeyPEM'] as String?,
        transport: TransportMode.lan,
      ));
    } catch (_) {}
  }

  void _onTcpConnection(Socket socket) {
    final buffer = StringBuffer();
    socket.listen((bytes) {
      buffer.write(utf8.decode(bytes, allowMalformed: true));
      final raw = buffer.toString();
      final lines = raw.split('\n');
      for (int i = 0; i < lines.length - 1; i++) {
        _processMessage(lines[i]);
      }
      buffer.clear();
      buffer.write(lines.last);
    }, onDone: socket.destroy);
  }

  void _processMessage(String raw) {
    if (raw.trim().isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _packetController.add(InboundPacket(
        peerUuid: json['from'] as String,
        peerShortId: json['fromShortId'] as String? ?? '',
        peerDisplayName: json['fromName'] as String? ?? 'Unknown',
        payload: raw,
        transport: TransportMode.lan,
      ));
    } catch (_) {}
  }

  @override
  Future<bool> send(String peerUuid, String payload) async {
    final conn = _peerConns[peerUuid];
    if (conn == null) return false;
    try {
      final socket = await Socket.connect(conn.address, conn.port,
          timeout: const Duration(seconds: 5));
      socket.write('$payload\n');
      await socket.flush();
      await socket.close();
      return true;
    } catch (e) {
      debugPrint('[LAN] Send to $peerUuid failed: $e');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await stopScanning();
    _packetController.close();
    _announcementController.close();
  }
}

class _PeerConn {
  final InternetAddress address;
  final int port;
  _PeerConn(this.address, this.port);
}
