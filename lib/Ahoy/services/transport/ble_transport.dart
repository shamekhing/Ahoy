import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../core/constants.dart';
import '../../core/enums.dart';
import '../../core/logging.dart';
import 'transport_interface.dart';

/// BLE transport with sequenced chunking for out-of-order delivery.
class BleTransport implements TransportInterface {
  static const _advertiserChannel = MethodChannel('ble_advertiser');

  @override
  TransportMode get mode => TransportMode.ble;

  final _packetController = StreamController<InboundPacket>.broadcast();
  final _announcementController =
      StreamController<PeerAnnouncement>.broadcast();
  final int _maxPayloadBytes;
  final int _maxActiveAssemblies;

  @override
  Stream<InboundPacket> get packetStream => _packetController.stream;
  @override
  Stream<PeerAnnouncement> get announcementStream =>
      _announcementController.stream;

  StreamSubscription? _scanSub;
  StreamSubscription? _scanStateSub;

  // Chunk reassembly: msgId → { seqNo → decoded chunk bytes }
  final Map<String, Map<int, Uint8List>> _chunkBuffer = {};
  final Map<String, int> _chunkTotal = {};
  final Map<String, int> _chunkByteCounts = {};
  // Timestamp of last chunk received per msgId — used to evict stale assemblies.
  final Map<String, DateTime> _chunkTimestamps = {};
  Timer? _chunkCleanupTimer;

  // Devices seen in scan results — keyed by remoteId (BT MAC).
  final Map<String, BluetoothDevice> _scannedDevices = {};
  // Active GATT connections for sending — keyed by remoteId.
  final Map<String, BluetoothDevice> _connectedDevices = {};
  // One subscription per connected device — cancelled on disconnect or dispose.
  final Map<String, StreamSubscription> _connStateSubs = {};

  // Used to filter out our own device from BLE scan results.
  String? _myShortId;

  BleTransport({
    int maxPayloadBytes = AhoyConstants.bleMaxPayloadBytes,
    int maxActiveAssemblies = AhoyConstants.bleMaxActiveAssemblies,
  }) : _maxPayloadBytes = maxPayloadBytes,
       _maxActiveAssemblies = maxActiveAssemblies;

  int get _maxTotalChunks {
    final chunks = (_maxPayloadBytes / AhoyConstants.bleChunkSize).ceil();
    return chunks < 1 ? 1 : chunks;
  }

  int get _maxChunkDataLength => ((AhoyConstants.bleChunkSize + 2) ~/ 3) * 4;

  @visibleForTesting
  void debugReceiveChunk(String rawChunk, String deviceAddress) {
    _receiveChunk(rawChunk, deviceAddress);
  }

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  }) async {
    _myShortId = shortId;
    // Register here so GATT writes arriving right after the server opens are handled.
    _advertiserChannel.setMethodCallHandler(_onBleMethodCall);

    if (!Platform.isAndroid) return;

    // Payload goes in the BLE scan response alongside the service UUID.
    // Scan response budget: 31 bytes - 2 (field overhead) - 16 (128-bit UUID) = 13 bytes.
    // Format: shortId (6 bytes) + 0x00 + displayName (up to 6 bytes) = 13 bytes max.
    final nameBytes = displayName.codeUnits.take(6).toList();
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
      ahoyLog('[BLE] advertising started');
    } catch (e) {
      ahoyLog('[BLE] startAdvertising failed', e);
    }
  }

  Future<dynamic> _onBleMethodCall(MethodCall call) async {
    if (call.method == 'onBleChunkReceived') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final chunk = args['chunk'] as String? ?? '';
      final deviceAddress = args['deviceAddress'] as String? ?? '';
      if (chunk.isNotEmpty) _receiveChunk(chunk, deviceAddress);
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (!Platform.isAndroid) return;
    try {
      await _advertiserChannel.invokeMethod('stopAdvertising');
    } catch (e) {
      ahoyLog('[BLE] stopAdvertising failed', e);
    }
  }

  bool _scanning = false;
  Timer? _scanRestartTimer;

  // Android allows at most 5 scan starts in 30 s.  We start conservatively at
  // 8 s and double on each consecutive failure, so we never exceed the limit
  // even during repeated registration errors.
  int _backoffSeconds = 8;
  static const int _backoffMax = 120;

  // Set to true only after startScan() returns without throwing.
  // The isScanning listener uses this to distinguish "scan ended naturally"
  // (should restart) from "scan failed to start" (catch block already
  // scheduled the restart — don't schedule a second one).
  bool _lastStartSucceeded = false;

  @override
  Future<void> startScanning() async {
    // Register the Kotlin→Dart handler here so inbound GATT writes are
    // received even when startAdvertising() hasn't been called yet.
    _advertiserChannel.setMethodCallHandler(_onBleMethodCall);
    _scanning = true;
    _scanSub ??= FlutterBluePlus.onScanResults.listen(_onScanResult);
    _chunkCleanupTimer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => _evictStaleChunks(),
    );
    _scanStateSub ??= FlutterBluePlus.isScanning.listen((active) {
      // Only react to the scan stopping when the PREVIOUS start actually
      // succeeded.  If it failed, the catch block in _restartScan() already
      // scheduled a backoff retry — reacting here would create a second timer.
      if (!active && _scanning && _lastStartSucceeded) {
        _lastStartSucceeded = false;
        _scheduleScanRestart();
      }
    });
    await _restartScan();
  }

  void _scheduleScanRestart() {
    _scanRestartTimer?.cancel();
    _scanRestartTimer = Timer(Duration(seconds: _backoffSeconds), () {
      if (_scanning) _restartScan();
    });
  }

  Future<void> _restartScan() async {
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(AhoyConstants.bleServiceUuid)],
      );
      // Success — reset backoff so the next natural restart uses the minimum.
      _lastStartSucceeded = true;
      _backoffSeconds = 8;
      ahoyLog('[BLE] scan started');
    } catch (e) {
      _lastStartSucceeded = false;
      _backoffSeconds = (_backoffSeconds * 2).clamp(8, _backoffMax);
      ahoyLog('[BLE] scan failed; retry scheduled', e);
      if (_scanning) _scheduleScanRestart();
    }
  }

  @override
  Future<void> stopScanning() async {
    _scanning = false;
    _scanRestartTimer?.cancel();
    _scanRestartTimer = null;
    _chunkCleanupTimer?.cancel();
    _chunkCleanupTimer = null;
    await _scanStateSub?.cancel();
    _scanStateSub = null;
    if (!Platform.isAndroid) {
      await _scanSub?.cancel();
      _scanSub = null;
      return;
    }
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
  }

  void _evictStaleChunks() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    final stale = _chunkTimestamps.entries
        .where((e) => e.value.isBefore(cutoff))
        .map((e) => e.key)
        .toList();
    for (final id in stale) {
      _chunkBuffer.remove(id);
      _chunkTotal.remove(id);
      _chunkByteCounts.remove(id);
      _chunkTimestamps.remove(id);
    }
    if (stale.isNotEmpty) {
      ahoyLog('[BLE] evicted stale chunk assemblies');
    }
  }

  void _onScanResult(List<ScanResult> results) {
    for (final result in results) {
      // Cache the device so send() can connect to it later.
      _scannedDevices[result.device.remoteId.str] = result.device;
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
      // Filter own device by shortId: the remote ID is a BT MAC, _myUuid is
      // an Ahoy UUID — they can never match, so shortId is the right signal.
      final deviceId = result.device.remoteId.str;
      if (_myShortId != null && shortId == _myShortId) return;

      _announcementController.add(
        PeerAnnouncement(
          uuid: deviceId,
          shortId: shortId,
          displayName: displayName,
          transport: TransportMode.ble,
        ),
      );
    } catch (_) {}
  }

  @override
  Future<bool> send(String peerUuid, String payload) async {
    try {
      final device = await _getOrConnect(peerUuid);
      if (device == null) return false;
      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == Guid(AhoyConstants.bleServiceUuid),
        orElse: () => throw Exception('BLE service not found'),
      );
      final char = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(AhoyConstants.bleCharacteristicUuid),
        orElse: () => throw Exception('BLE characteristic not found'),
      );
      return _sendChunked(char, payload);
    } catch (e) {
      ahoyLog('[BLE] send failed', e);
      _connectedDevices.remove(peerUuid);
      return false;
    }
  }

  Future<BluetoothDevice?> _getOrConnect(String peerUuid) async {
    // Return cached connection if still connected.
    final existing = _connectedDevices[peerUuid];
    if (existing != null && existing.isConnected) return existing;

    // Find device from scan cache or connected system devices.
    BluetoothDevice? device = _scannedDevices[peerUuid];
    device ??= FlutterBluePlus.connectedDevices
        .where((d) => d.remoteId.str == peerUuid)
        .firstOrNull;

    if (device == null) {
      ahoyLog('[BLE] device not in scan cache');
      return null;
    }

    try {
      await device.connect(timeout: const Duration(seconds: 10));
      _connectedDevices[peerUuid] = device;
      // Cancel any previous subscription before attaching a new one so we
      // never accumulate multiple listeners on the same device stream.
      await _connStateSubs[peerUuid]?.cancel();
      _connStateSubs[peerUuid] = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevices.remove(peerUuid);
          _connStateSubs.remove(peerUuid)?.cancel();
        }
      });
      return device;
    } catch (e) {
      ahoyLog('[BLE] connect failed', e);
      return null;
    }
  }

  Future<bool> _sendChunked(
    BluetoothCharacteristic char,
    String payload,
  ) async {
    final msgId = DateTime.now().millisecondsSinceEpoch.toString();
    final bytes = utf8.encode(payload);
    if (bytes.length > _maxPayloadBytes) {
      ahoyLog('[BLE] refusing oversized payload');
      return false;
    }

    final chunkSize = AhoyConstants.bleChunkSize;
    final totalChunks = (bytes.length / chunkSize).ceil();
    if (totalChunks == 0 || totalChunks > _maxTotalChunks) return false;

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
    return true;
  }

  void _receiveChunk(String rawChunk, String deviceAddress) {
    try {
      if (rawChunk.length > _maxChunkDataLength + 160) return;
      final json = jsonDecode(rawChunk) as Map<String, dynamic>;
      final msgId = json['m'] as String? ?? '';
      final seq = json['seq'] as int? ?? -1;
      final total = json['total'] as int? ?? -1;
      final data = json['data'] as String? ?? '';

      if (msgId.isEmpty || msgId.length > 64) return;
      if (total <= 0 || total > _maxTotalChunks) return;
      if (seq < 0 || seq >= total) return;
      if (data.isEmpty || data.length > _maxChunkDataLength) return;

      final existingTotal = _chunkTotal[msgId];
      if (existingTotal != null && existingTotal != total) {
        _dropAssembly(msgId);
        return;
      }

      if (!_chunkBuffer.containsKey(msgId) &&
          _chunkBuffer.length >= _maxActiveAssemblies) {
        _evictOldestAssembly();
      }

      final bytes = Uint8List.fromList(base64.decode(data));
      if (bytes.length > AhoyConstants.bleChunkSize) return;

      _chunkBuffer.putIfAbsent(msgId, () => {});
      _chunkTotal[msgId] = total;
      final previousBytes = _chunkBuffer[msgId]![seq]?.length ?? 0;
      _chunkBuffer[msgId]![seq] = bytes;
      final byteCount =
          (_chunkByteCounts[msgId] ?? 0) - previousBytes + bytes.length;
      if (byteCount > _maxPayloadBytes) {
        _dropAssembly(msgId);
        return;
      }
      _chunkByteCounts[msgId] = byteCount;
      _chunkTimestamps[msgId] = DateTime.now();

      if (_chunkBuffer[msgId]!.length == total) {
        final sortedKeys = _chunkBuffer[msgId]!.keys.toList()..sort();
        final allBytes = sortedKeys
            .expand((k) => _chunkBuffer[msgId]![k]!)
            .toList();
        final payload = utf8.decode(allBytes);
        _dropAssembly(msgId);

        // Parse peer identity from the assembled payload so the packet
        // carries the real Ahoy UUID rather than the BT MAC address.
        String peerUuid = deviceAddress;
        String peerShortId = '';
        String peerName = 'Unknown';
        try {
          final pJson = jsonDecode(payload) as Map<String, dynamic>;
          peerUuid = pJson['from'] as String? ?? deviceAddress;
          peerShortId = pJson['fromShortId'] as String? ?? '';
          peerName = pJson['fromName'] as String? ?? 'Unknown';
        } catch (_) {}

        _packetController.add(
          InboundPacket(
            peerUuid: peerUuid,
            peerShortId: peerShortId,
            peerDisplayName: peerName,
            payload: payload,
            transport: TransportMode.ble,
          ),
        );
      }
    } catch (e) {
      ahoyLog('[BLE] chunk parse error', e);
    }
  }

  void _dropAssembly(String msgId) {
    _chunkBuffer.remove(msgId);
    _chunkTotal.remove(msgId);
    _chunkByteCounts.remove(msgId);
    _chunkTimestamps.remove(msgId);
  }

  void _evictOldestAssembly() {
    if (_chunkTimestamps.isEmpty) return;
    var oldestId = _chunkTimestamps.keys.first;
    var oldestTimestamp = _chunkTimestamps[oldestId]!;
    for (final entry in _chunkTimestamps.entries.skip(1)) {
      if (entry.value.isBefore(oldestTimestamp)) {
        oldestId = entry.key;
        oldestTimestamp = entry.value;
      }
    }
    _dropAssembly(oldestId);
  }

  @override
  Future<void> dispose() async {
    _advertiserChannel.setMethodCallHandler(null);
    await stopScanning();
    for (final sub in _connStateSubs.values) {
      await sub.cancel();
    }
    _connStateSubs.clear();
    for (final d in _connectedDevices.values) {
      await d.disconnect();
    }
    _connectedDevices.clear();
    _scannedDevices.clear();
    _chunkBuffer.clear();
    _chunkTotal.clear();
    _chunkByteCounts.clear();
    _chunkTimestamps.clear();
    _packetController.close();
    _announcementController.close();
  }
}
