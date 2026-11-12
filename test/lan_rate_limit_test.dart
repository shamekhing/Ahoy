import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LAN messages are rate limited per address', () async {
    final transport = LanTransport(discoveryPort: 0, messagingPort: 0);
    await transport.startScanning();
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;

    var received = 0;
    final sub = transport.packetStream.listen((_) => received++);
    addTearDown(sub.cancel);

    Future<void> sendBatch(int count) async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      final builder = BytesBuilder();
      final payload = utf8.encode(jsonEncode({'from': 'flood'}));
      for (var i = 0; i < count; i++) {
        builder.add(payload);
        builder.add([10]);
      }
      socket.add(builder.takeBytes());
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close();
    }

    // Three connections from one address: 30 messages offered, the window
    // allows at most lanMaxMessagesPerAddressPerWindow.
    await sendBatch(10);
    await sendBatch(10);
    await sendBatch(10);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      received,
      lessThanOrEqualTo(AhoyConstants.lanMaxMessagesPerAddressPerWindow),
    );
    expect(received, greaterThan(0));
  });

  test('concurrent LAN connections are bounded', () async {
    final transport = LanTransport(discoveryPort: 0, messagingPort: 0);
    await transport.startScanning();
    addTearDown(transport.dispose);
    final port = transport.debugMessagingPort!;

    final sockets = <Socket>[];
    for (var i = 0; i < 40; i++) {
      try {
        sockets
            .add(await Socket.connect(InternetAddress.loopbackIPv4, port));
      } catch (_) {
        // A refused connection is exactly what the cap should produce.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      transport.debugActiveConnections,
      lessThanOrEqualTo(AhoyConstants.lanMaxConnections),
    );
    for (final socket in sockets) {
      try {
        socket.destroy();
      } catch (_) {}
    }
  });
}
