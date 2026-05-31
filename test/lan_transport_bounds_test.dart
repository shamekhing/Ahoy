import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts bounded LAN TCP payloads', () async {
    final transport = await _startedTransport(maxPayloadBytes: 256);
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;
    final packetFuture = transport.packetStream.first.timeout(
      const Duration(seconds: 1),
    );

    await _sendRaw(
      port,
      '${jsonEncode({'from': 'peer-1', 'fromShortId': '123456', 'fromName': 'Peer', 'msgType': 'chat'})}\n',
    );

    final packet = await packetFuture;
    expect(packet.peerUuid, 'peer-1');
    expect(packet.peerShortId, '123456');
    expect(packet.peerDisplayName, 'Peer');
    expect(packet.transport, TransportMode.lan);
  });

  test('drops oversized LAN TCP payloads', () async {
    final transport = await _startedTransport(maxPayloadBytes: 96);
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    await _sendRaw(
      port,
      '${jsonEncode({'from': 'peer-1', 'fromShortId': '123456', 'fromName': 'Peer', 'padding': 'x' * 200})}\n',
    );

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(packets, isEmpty);
  });

  test('limits LAN TCP messages per connection', () async {
    final transport = await _startedTransport(
      maxPayloadBytes: 256,
      maxMessagesPerConnection: 1,
    );
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    final first = jsonEncode({'from': 'peer-1', 'msgType': 'chat'});
    final second = jsonEncode({'from': 'peer-2', 'msgType': 'chat'});
    await _sendRaw(port, '$first\n$second\n');

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(packets.map((p) => p.peerUuid), ['peer-1']);
  });
}

Future<LanTransport> _startedTransport({
  required int maxPayloadBytes,
  int maxMessagesPerConnection = 8,
}) async {
  final transport = LanTransport(
    discoveryPort: 0,
    messagingPort: 0,
    maxPayloadBytes: maxPayloadBytes,
    maxMessagesPerConnection: maxMessagesPerConnection,
    tcpIdleTimeout: const Duration(milliseconds: 250),
  );
  await transport.startScanning();
  expect(transport.debugMessagingPort, isNotNull);
  return transport;
}

Future<void> _sendRaw(int port, String raw) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  try {
    socket.add(utf8.encode(raw));
    await socket.flush();
  } catch (_) {
    // The server intentionally resets invalid test payloads.
  } finally {
    socket.destroy();
  }
}
