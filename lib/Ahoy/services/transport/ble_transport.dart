import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../core/constants.dart';
import '../../core/enums.dart';
import 'transport_interface.dart';

/// BLE transport with sequenced chunking for out-of-order delivery.
class BleTransport implements TransportInterface {
  static const _advertiserChannel = MethodChannel('ble_advertiser');

  @override
  TransportMode get mode => TransportMode.ble;

  final _packetController = StreamController<InboundPacket>.broadcast();
  final _announcementController = StreamController<PeerAnnouncement>.broadcast();

  @override
  Stream<InboundPacket> get packetStream => _packetController.stream;
  @override
  Stream<PeerAnnouncement> get announcementStream => _announcementController.stream;

  StreamSubscription? _scanSub;
  StreamSubscription? _scanStateSub;

  // Chunk reassembly: msgId → { seqNo → base64Chunk }
  final Map<String, Map<int, String>> _chunkBuffer = {};
  final Map<String, int> _chunkTotal = {};

  // Connected devices for sending
  final Map<String, BluetoothDevice> _connectedDevices = {};

  // Used to filter out our own device from BLE scan results.
  String? _myUuid;

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  }) async {
    _myUuid = uuid;
    if (!Platform.isAndroid) return;

    // Build a compact identity payload that fits in 20 bytes of service data.
    // Format: shortId (6 bytes ASCII) + null + displayName (truncated).
    final nameBytes = displayName.codeUnits.take(13).toList();
    final payload = Uint8List.fromList([
      ...shortId.codeUnits.take(6),
      0x00,
      ...nameBytes,
    ]);

    try {
      await _advertiserChannel.invokeMethod<bool>('startAdvertising', {
        'serviceUuid': AhoyConstants.bleServiceUuid,
        'payload': payload,
      });
      debugPrint('[BLE] Advertising started ($shortId)');
    } catch (e) {
      debugPrint('[BLE] startAdvertising failed: $e');
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (!Platform.isAndroid) return;
    try {
      await _advertiserChannel.invokeMethod('stopAdvertising');
    } catch (e) {
      debugPrint('[BLE] stopAdvertising failed: $e');
    }
  }

  bool _scanning = false;

  @override
  Future<void> startScanning() async {
    _scanning = true;
    _scanSub ??= FlutterBluePlus.onScanResults.listen(_onScanResult);
    // Restart the scan whenever Flutter Blue Plus reports it has stopped,
    // so discovery stays live indefinitely (the SDK stops after its timeout).
    _scanStateSub ??= FlutterBluePlus.isScanning.listen((active) {
      if (!active && _scanning) _restartScan();
    });
    await _restartScan();
  }

  Future<void> _restartScan() async {
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(AhoyConstants.bleServiceUuid)],
      );
    } catch (e) {
      debugPrint('[BLE] Scan failed: $e');
    }
  }

  @override
  Future<void> stopScanning() async {
    _scanning = false;
    await _scanStateSub?.cancel();
    _scanStateSub = null;
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
  }

  void _onScanResult(List<ScanResult> results) {
    for (final result in results) {
      _parseAnnouncement(result);
    }
  }

  void _parseAnnouncement(ScanResult result) {
    try {
      final adData = result.advertisementData;
      final serviceData = adData.serviceData;
      final bytes = serviceData[Guid(AhoyConstants.bleServiceUuid)];
      if (bytes == null || bytes.isEmpty) return;

      // Compact format: shortId(6) + 0x00 + displayName
      final nullIdx = bytes.indexOf(0x00);
      if (nullIdx < 0) return;
      final shortId = String.fromCharCodes(bytes.sublist(0, nullIdx));
      final displayName = bytes.length > nullIdx + 1
          ? String.fromCharCodes(bytes.sublist(nullIdx + 1))
          : 'Unknown';

      // Use the remote device address as a stable peer identifier when
      // scanning — we learn the real UUID on first message exchange.
      final deviceId = result.device.remoteId.str;
      if (deviceId == _myUuid) return;

      _announcementController.add(PeerAnnouncement(
        uuid: deviceId,
        shortId: shortId,
        displayName: displayName,
        transport: TransportMode.ble,
      ));
    } catch (_) {}
  }

  @override
  Future<bool> send(String peerUuid, String payload) async {
    final device = _connectedDevices[peerUuid];
    if (device == null) return false;
    try {
      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == Guid(AhoyConstants.bleServiceUuid),
        orElse: () => throw Exception('BLE service not found'),
      );
      final char = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(AhoyConstants.bleCharacteristicUuid),
        orElse: () => throw Exception('BLE characteristic not found'),
      );
      await _sendChunked(char, payload);
      return true;
    } catch (e) {
      debugPrint('[BLE] Send failed: $e');
      return false;
    }
  }

  Future<void> _sendChunked(BluetoothCharacteristic char, String payload) async {
    final msgId = DateTime.now().millisecondsSinceEpoch.toString();
    final bytes = utf8.encode(payload);
    final chunkSize = AhoyConstants.bleChunkSize;
    final totalChunks = (bytes.length / chunkSize).ceil();

    for (int seq = 0; seq < totalChunks; seq++) {
      final start = seq * chunkSize;
      final end = (start + chunkSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(start, end);
      final envelope = jsonEncode({
        'm': msgId,
        'seq': seq,
        'total': totalChunks,
        'data': base64.encode(chunk),
      });
      await char.write(utf8.encode(envelope), withoutResponse: false);
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  void receiveChunk(String rawChunk, String peerUuid, String peerShortId, String peerName) {
    try {
      final json = jsonDecode(rawChunk) as Map<String, dynamic>;
      final msgId = json['m'] as String;
      final seq = json['seq'] as int;
      final total = json['total'] as int;
      final data = json['data'] as String;

      _chunkBuffer.putIfAbsent(msgId, () => {});
      _chunkTotal[msgId] = total;
      _chunkBuffer[msgId]![seq] = data;

      if (_chunkBuffer[msgId]!.length == total) {
        final sortedKeys = _chunkBuffer[msgId]!.keys.toList()..sort();
        final allBytes = sortedKeys
            .map((k) => base64.decode(_chunkBuffer[msgId]![k]!))
            .expand((b) => b)
            .toList();
        final payload = utf8.decode(allBytes);
        _chunkBuffer.remove(msgId);
        _chunkTotal.remove(msgId);

        _packetController.add(InboundPacket(
          peerUuid: peerUuid,
          peerShortId: peerShortId,
          peerDisplayName: peerName,
          payload: payload,
          transport: TransportMode.ble,
        ));
      }
    } catch (e) {
      debugPrint('[BLE] Chunk parse error: $e');
    }
  }

  @override
  Future<void> dispose() async {
    await stopScanning();
    for (final d in _connectedDevices.values) {
      await d.disconnect();
    }
    _connectedDevices.clear();
    _chunkBuffer.clear();
    _chunkTotal.clear();
    _packetController.close();
    _announcementController.close();
  }
}
