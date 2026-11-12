import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multiple messages arriving in one chunk are all processed', () async {
    final transport = await _startedTransport(maxPayloadBytes: 256);
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    final socket = await _connect(port);
    socket.add(utf8.encode(
      '${jsonEncode({'from': 'peer-1', 'msgType': 'chat'})}\n'
      '${jsonEncode({'from': 'peer-2', 'msgType': 'chat'})}\n',
    ));
    await socket.flush();
    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(packets.map((p) => p.peerUuid), ['peer-1', 'peer-2']);
  });

  test('CRLF-terminated messages keep their payload intact', () async {
    final transport = await _startedTransport(maxPayloadBytes: 256);
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;
    final packetFuture = transport.packetStream.first;

    final socket = await _connect(port);
    socket.add(utf8.encode(
      '${jsonEncode({'from': 'peer-cr', 'msgType': 'chat'})}\r\n',
    ));
    await socket.flush();
    await socket.close();

    final packet = await packetFuture.timeout(const Duration(seconds: 1));
    expect(packet.peerUuid, 'peer-cr');
  });

  test('an active connection cannot outlive the absolute lifetime cap',
      () async {
    final transport = await _startedTransport(
      maxPayloadBytes: 256,
      tcpIdleTimeout: const Duration(seconds: 10),
      tcpMaxLifetime: const Duration(milliseconds: 150),
    );
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    // Activity keeps the idle timer alive; the lifetime cap must not care.
    final socket = await _connect(port);
    socket.add(utf8.encode('${jsonEncode({'from': 'peer-1'})}\n'));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    socket.add(utf8.encode('${jsonEncode({'from': 'peer-2'})}\n'));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    socket.destroy();

    expect(packets.map((p) => p.peerUuid), ['peer-1']);
  });

  test('the aggregate buffer budget drops runaway connections', () async {
    final transport = await _startedTransport(
      maxPayloadBytes: 4096,
      maxTotalBufferedBytes: 512,
      tcpIdleTimeout: const Duration(seconds: 10),
      tcpMaxLifetime: const Duration(seconds: 10),
    );
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;
    final packets = <InboundPacket>[];
    final sub = transport.packetStream.listen(packets.add);
    addTearDown(sub.cancel);

    // 600 unterminated bytes exceed the 512-byte aggregate budget.
    final flood = await _connect(port);
    final serverClosed = Completer<void>();
    flood.listen(
      (_) {},
      onDone: serverClosed.complete,
      onError: (_) {
        if (!serverClosed.isCompleted) serverClosed.complete();
      },
      cancelOnError: true,
    );
    flood.add(utf8.encode('x' * 600));
    await flood.flush();
    // The server closes the connection once the budget trips.
    await serverClosed.future.timeout(const Duration(seconds: 2));

    // The budget is released with the connection, so normal traffic works.
    final healthy = await _connect(port);
    healthy.add(utf8.encode('${jsonEncode({'from': 'peer-ok'})}\n'));
    await healthy.flush();
    await healthy.close();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(packets.map((p) => p.peerUuid), ['peer-ok']);
  });
}

Future<LanTransport> _startedTransport({
  required int maxPayloadBytes,
  int maxMessagesPerConnection = 8,
  Duration tcpIdleTimeout = const Duration(milliseconds: 250),
  Duration tcpMaxLifetime = const Duration(
    seconds: AhoyConstants.lanTcpMaxLifetimeSeconds,
  ),
  int? maxTotalBufferedBytes,
}) async {
  final transport = LanTransport(
    discoveryPort: 0,
    messagingPort: 0,
    maxPayloadBytes: maxPayloadBytes,
    maxMessagesPerConnection: maxMessagesPerConnection,
    tcpIdleTimeout: tcpIdleTimeout,
    tcpMaxLifetime: tcpMaxLifetime,
    maxTotalBufferedBytes: maxTotalBufferedBytes,
  );
  await transport.startScanning();
  expect(transport.debugMessagingPort, isNotNull);
  return transport;
}

Future<Socket> _connect(int port) =>
    Socket.connect(InternetAddress.loopbackIPv4, port);
