import 'dart:convert';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/transport/ble_transport.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts bounded BLE chunk assemblies', () async {
    final transport = BleTransport(maxPayloadBytes: 128);
    addTearDown(transport.dispose);
    final packetFuture = transport.packetStream.first.timeout(
      const Duration(seconds: 1),
    );

    transport.debugReceiveChunk(
      _chunk(
        msgId: 'message-1',
        seq: 0,
        total: 1,
        payload: jsonEncode({
          'from': 'peer-1',
          'fromShortId': '123456',
          'fromName': 'Peer',
          'msgType': 'chat',
        }),
      ),
      'device-1',
    );

    final packet = await packetFuture;
    expect(packet.peerUuid, 'peer-1');
    expect(packet.peerShortId, '123456');
    expect(packet.peerDisplayName, 'Peer');
    expect(packet.transport, TransportMode.ble);
  });

  test('drops BLE chunks with invalid sequence metadata', () async {
    final transport = BleTransport(maxPayloadBytes: 128);
    addTearDown(transport.dispose);
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    transport.debugReceiveChunk(
      _chunk(msgId: 'message-1', seq: 3, total: 1, payload: 'ignored'),
      'device-1',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(packets, isEmpty);
  });

  test('drops oversized BLE chunk data', () async {
    final transport = BleTransport(maxPayloadBytes: 512);
    addTearDown(transport.dispose);
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);
    final oversizedChunk = 'x' * (AhoyConstants.bleChunkSize + 1);

    transport.debugReceiveChunk(
      _chunk(msgId: 'message-1', seq: 0, total: 1, payload: oversizedChunk),
      'device-1',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(packets, isEmpty);
  });

  test('drops oversized BLE assembled payloads', () async {
    final transport = BleTransport(maxPayloadBytes: 8);
    addTearDown(transport.dispose);
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    transport.debugReceiveChunk(
      _chunk(msgId: 'message-1', seq: 0, total: 1, payload: 'too large'),
      'device-1',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(packets, isEmpty);
  });

  test(
    'evicts oldest BLE assembly when active assembly cap is reached',
    () async {
      final transport = BleTransport(
        maxPayloadBytes: 512,
        maxActiveAssemblies: 1,
      );
      addTearDown(transport.dispose);
      final packets = <InboundPacket>[];
      final sub = transport.packetStream.listen(packets.add);
      addTearDown(sub.cancel);

      transport.debugReceiveChunk(
        _chunk(msgId: 'old', seq: 0, total: 2, payload: 'old-'),
        'device-1',
      );
      transport.debugReceiveChunk(
        _chunk(msgId: 'new', seq: 0, total: 2, payload: 'new-'),
        'device-1',
      );
      transport.debugReceiveChunk(
        _chunk(msgId: 'new', seq: 1, total: 2, payload: 'done'),
        'device-1',
      );
      transport.debugReceiveChunk(
        _chunk(msgId: 'old', seq: 1, total: 2, payload: 'ignored'),
        'device-1',
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(packets.map((packet) => packet.payload), ['new-done']);
    },
  );

  test('assemblies from different devices with identical msg ids do not collide (audit L-3)', () async {
    final transport = BleTransport(maxPayloadBytes: 1024);
    addTearDown(transport.dispose);
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    // Two devices, same message id, interleaved chunks. The halves join into
    // a valid JSON payload per device so the peer identity parses.
    transport.debugReceiveChunk(
      _chunk(msgId: 'same-id', seq: 0, total: 2, payload: '{"from":"peer-A"'),
      'device-A',
    );
    transport.debugReceiveChunk(
      _chunk(msgId: 'same-id', seq: 0, total: 2, payload: '{"from":"peer-B"'),
      'device-B',
    );
    transport.debugReceiveChunk(
      _chunk(msgId: 'same-id', seq: 1, total: 2, payload: '}'),
      'device-A',
    );
    transport.debugReceiveChunk(
      _chunk(msgId: 'same-id', seq: 1, total: 2, payload: '}'),
      'device-B',
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(packets, hasLength(2));
    final uuids = packets.map((p) => p.peerUuid).toSet();
    expect(uuids, {'peer-A', 'peer-B'},
        reason: 'each device reassembles its own payload');
  });

  test('BLE display names are UTF-8 truncated without corruption (audit L-9)', () {
    // ASCII fits fully.
    expect(utf8.decode(BleTransport.bleNameBytes('Hello')), 'Hello');
    // Six bytes of two-character e-accents survive intact.
    expect(utf8.decode(BleTransport.bleNameBytes('\u00e9\u00e9\u00e9')), '\u00e9\u00e9\u00e9');
    // A seventh byte would split a multibyte character: dropped entirely.
    final truncated = utf8.decode(BleTransport.bleNameBytes('\u00e9\u00e9\u00e9\u00e9'));
    expect(truncated, '\u00e9\u00e9\u00e9');
    expect(truncated.codeUnits, isNot(contains(0xFFFD)),
        reason: 'no replacement characters may appear');
  });

  test('idle GATT connections are released after the threshold (audit L-9)', () {
    final now = DateTime.now();
    expect(BleTransport.isIdleConnection(now.subtract(const Duration(minutes: 6)), now, const Duration(minutes: 5)), isTrue);
    expect(BleTransport.isIdleConnection(now.subtract(const Duration(minutes: 1)), now, const Duration(minutes: 5)), isFalse);
    expect(BleTransport.isIdleConnection(null, now, const Duration(minutes: 5)), isTrue,
        reason: 'a connection with no recorded use is releasable');
  });
}

String _chunk({
  required String msgId,
  required int seq,
  required int total,
  required String payload,
}) {
  return jsonEncode({
    'm': msgId,
    'seq': seq,
    'total': total,
    'data': base64.encode(utf8.encode(payload)),
  });
}


