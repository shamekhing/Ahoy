import 'dart:convert';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/transport/wifi_direct_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'WiFi Direct refuses oversized outbound payloads before platform send',
    () async {
      final transport = WiFiDirectTransport(maxPayloadBytes: 4);
      addTearDown(transport.dispose);

      final sent = await transport.debugSendBytes([1, 2, 3, 4, 5]);

      expect(sent, isFalse);
    },
  );

  test('WiFi Direct drops oversized inbound platform payloads', () async {
    final transport = WiFiDirectTransport(maxPayloadBytes: 4);
    addTearDown(transport.dispose);
    var emitted = false;
    final sub = transport.packetStream.listen((_) {
      emitted = true;
    });
    addTearDown(sub.cancel);

    transport.debugHandleDataReceived({
      'data': Uint8List.fromList(utf8.encode('{"from":"peer-1"}')),
      'senderIP': '10.0.0.2',
    });
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isFalse);
  });

  test('WiFi Direct identity announcements carry peer public keys', () async {
    final transport = WiFiDirectTransport(maxPayloadBytes: 4096);
    addTearDown(transport.dispose);
    final announcementFuture = transport.announcementStream.first;

    transport.debugHandleDataReceived({
      'data': Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'wdIdentity',
            'uuid': 'peer-1',
            'shortId': 'ABC123',
            'displayName': 'Peer',
            'publicKeyPEM': 'peer-public-key',
          }),
        ),
      ),
      'senderIP': '10.0.0.2',
    });

    final announcement = await announcementFuture;
    expect(announcement.uuid, 'peer-1');
    expect(announcement.publicKeyPEM, 'peer-public-key');
    expect(announcement.transport, TransportMode.wifiDirect);
  });
}
