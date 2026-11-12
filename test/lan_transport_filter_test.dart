import 'package:ahoy/Ahoy/services/transport/lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TCP peers outside announced subnets are rejected (audit M-4)', () async {
    final transport = LanTransport(
      discoveryPort: 0,
      messagingPort: 0,
    );
    addTearDown(transport.dispose);

    // Loopback always passes it serves local tooling and same-device
    // clients, and the existing bounds tests rely on it.
    expect(transport.debugIsAllowedTcpPeer('127.0.0.1'), isTrue);

    // Nothing has announced itself yet every other network is rejected.
    expect(transport.debugIsAllowedTcpPeer('10.0.0.5'), isFalse);

    // Once a subnet announces itself, hosts inside its /24 become reachable…
    transport.debugAllowSubnet('10.0.0');
    expect(transport.debugIsAllowedTcpPeer('10.0.0.5'), isTrue);
    expect(transport.debugIsAllowedTcpPeer('10.0.0.254'), isTrue);
    // …but neighbouring subnets stay blocked.
    expect(transport.debugIsAllowedTcpPeer('10.0.1.5'), isFalse);
    expect(transport.debugIsAllowedTcpPeer('10.1.0.5'), isFalse);
    expect(transport.debugIsAllowedTcpPeer('10.0.254.254'), isFalse);
  });

  test('announced ports are never trusted (audit M-5)', () async {
    // The announce wire format no longer carries a port field, and inbound
    // announces ignore any port the peer may still send. The messaging port
    // is fixed on both ends, so a spoofed announce cannot point the connect
    // target at an arbitrary host:port.
    final transport = LanTransport(
      discoveryPort: 0,
      messagingPort: 45679,
    );
    addTearDown(transport.dispose);

    expect(transport.debugMessagingPort, isNull);
    await transport.startScanning();
    addTearDown(transport.dispose);

    // The TCP server is bound to the configured messaging port.
    expect(transport.debugMessagingPort, 45679);
  });
}