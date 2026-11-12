import 'dart:async';
import 'dart:convert';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/transport/transport_interface.dart';
import 'package:ahoy/Ahoy/services/transport/wifi_direct_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final transport = WiFiDirectTransport(maxPayloadBytes: 4096, crypto: crypto);
    addTearDown(transport.dispose);
    final announcementFuture = transport.announcementStream.first;

    final identity = <String, dynamic>{
      'type': 'wdIdentity',
      'uuid': 'peer-1',
      'shortId': 'ABC123',
      'displayName': 'Peer',
      'publicKeyPEM': keys['publicKey'],
      'timestamp': DateTime.now().toIso8601String(),
    };
    identity['signature'] = crypto.signAnnouncement(
      uuid: 'peer-1',
      shortId: 'ABC123',
      displayName: 'Peer',
      publicKeyPEM: keys['publicKey'],
    );
    transport.debugHandleDataReceived({
      'data': Uint8List.fromList(utf8.encode(jsonEncode(identity))),
      'senderIP': '10.0.0.2',
    });

    final announcement = await announcementFuture;
    expect(announcement.uuid, 'peer-1');
    expect(announcement.publicKeyPEM, keys['publicKey']);
    expect(announcement.transport, TransportMode.wifiDirect);
  });

  test('WiFi Direct drops unsigned identity packets (audit #5)', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);
    final transport = WiFiDirectTransport(maxPayloadBytes: 4096, crypto: crypto);
    addTearDown(transport.dispose);
    var emitted = false;
    final sub = transport.announcementStream.listen((_) => emitted = true);
    addTearDown(sub.cancel);

    transport.debugHandleDataReceived({
      'data': Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'wdIdentity',
            'uuid': 'peer-1',
            'shortId': 'ABC123',
            'displayName': 'Peer',
            'publicKeyPEM': keys['publicKey'],
          }),
        ),
      ),
      'senderIP': '10.0.0.2',
    });
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isFalse);
  });

  test('connect attempts expire via TTL instead of wedging peers (review #1/#2)', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wifi_direct'), (call) async {
      calls.add(call);
      return;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wifi_direct'), null));

    final transport = WiFiDirectTransport(
      maxPayloadBytes: 4096,
      connectAttemptTtl: Duration.zero,
    );
    addTearDown(transport.dispose);

    await transport.debugTryConnect('AA:BB:CC:DD:EE:FF');
    expect(
      calls.map((c) => c.method),
      contains('connect'),
    );
    // The attempt is tracked while fresh…
    expect(transport.debugConnectingAttemptCount, 1);
    // …and TTL expiry frees the peer for a retry instead of wedging it.
    transport.debugPruneConnectingAttempts();
    expect(transport.debugConnectingAttemptCount, 0);
  });

  test('concurrent connect attempts are tracked independently (review #1)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wifi_direct'), (call) async {
      if (call.method == 'connect') {
        // Never completes the attempt stays in flight.
        return Completer<void>().future;
      }
      return;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wifi_direct'), null));

    final transport = WiFiDirectTransport(maxPayloadBytes: 4096);
    addTearDown(transport.dispose);

    unawaited(transport.debugTryConnect('AA:BB:CC:DD:EE:01'));
    unawaited(transport.debugTryConnect('AA:BB:CC:DD:EE:02'));
    await Future<void>.delayed(Duration.zero);

    // Both attempts are tracked; nothing was cross-removed.
    expect(transport.debugConnectingAttemptCount, 2);
  });

  test('failed connect frees the address for an immediate retry', () async {
    final transport = WiFiDirectTransport(maxPayloadBytes: 4096);
    addTearDown(transport.dispose);

    // No platform handler registered → invokeMethod throws → the failure
    // path removes the attempt.
    await transport.debugTryConnect('AA:BB:CC:DD:EE:FF');
    expect(transport.debugConnectingAttemptCount, 0);

    // The peer can immediately be attempted again.
    await transport.debugTryConnect('AA:BB:CC:DD:EE:FF');
    expect(transport.debugConnectingAttemptCount, 0);
  });

  test('the first verified identity fixes the WiFi Direct route key (audit H-2)',
      () async {
    final crypto = CryptoService();
    final peerKeys = await crypto.generateKeyPair();
    crypto.activate(peerKeys['privateKey']!, peerKeys['publicKey']!);
    final attacker = CryptoService();
    final attackerKeys = await attacker.generateKeyPair();
    attacker.activate(attackerKeys['privateKey']!, attackerKeys['publicKey']!);

    final transport = WiFiDirectTransport(maxPayloadBytes: 4096, crypto: crypto);
    addTearDown(transport.dispose);
    final announcements = <PeerAnnouncement>[];
    final sub = transport.announcementStream.listen(announcements.add);
    addTearDown(sub.cancel);

    // Group owner: identity routes come from the TCP sender IP.
    transport.debugHandleConnectionEstablished({
      'isGroupOwner': true,
      'address': '',
    });

    _deliverIdentity(
      transport,
      crypto,
      uuid: 'peer-1',
      shortId: 'ABC123',
      displayName: 'Peer',
      key: peerKeys['publicKey']!,
      senderIP: '10.0.0.2',
    );
    await Future<void>.delayed(Duration.zero);

    expect(transport.debugUuidKeys['peer-1'], peerKeys['publicKey']);
    expect(transport.debugUuidToAddress['peer-1'], '10.0.0.2');
    expect(announcements, hasLength(1));

    // A forged identity claiming the same UUID with a different key changes
    // nothing: no announcement, no route rebind.
    _deliverIdentity(
      transport,
      attacker,
      uuid: 'peer-1',
      shortId: 'ABC123',
      displayName: 'Peer',
      key: attackerKeys['publicKey']!,
      senderIP: '10.0.0.9',
    );
    await Future<void>.delayed(Duration.zero);

    expect(announcements, hasLength(1));
    expect(transport.debugUuidKeys['peer-1'], peerKeys['publicKey']);
    expect(transport.debugUuidToAddress['peer-1'], '10.0.0.2',
        reason: 'the forged identity must not repoint the route');

    // The genuine peer rejoining from a new IP may move the route.
    _deliverIdentity(
      transport,
      crypto,
      uuid: 'peer-1',
      shortId: 'ABC123',
      displayName: 'Peer',
      key: peerKeys['publicKey']!,
      senderIP: '10.0.0.3',
    );
    await Future<void>.delayed(Duration.zero);

    expect(announcements, hasLength(2));
    expect(transport.debugUuidToAddress['peer-1'], '10.0.0.3');
  });

  test('auto-connect gives up on devices that never speak Ahoy (audit M-4)',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wifi_direct'),
            (call) async {
      calls.add(call);
      return;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wifi_direct'), null));

    final transport = WiFiDirectTransport(
      maxPayloadBytes: 4096,
      connectAttemptTtl: const Duration(milliseconds: 5),
    );
    addTearDown(transport.dispose);
    final printer = <String, String>{
      'deviceAddress': 'AA:BB:CC:DD:EE:99',
      'deviceName': 'Office Printer',
      'status': '0',
    };

    transport.debugHandlePeersDiscovered([printer]);
    expect(calls.where((c) => c.method == 'connect'), hasLength(1));

    // The attempt expires without any identity: strike one. Real delays keep
    // the TTL expiry independent of clock granularity.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    transport.debugPruneConnectingAttempts();
    transport.debugHandlePeersDiscovered([printer]);
    expect(calls.where((c) => c.method == 'connect'), hasLength(2));

    // Strike two: the cap trips and the device is left alone.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    transport.debugPruneConnectingAttempts();
    transport.debugHandlePeersDiscovered([printer]);
    expect(calls.where((c) => c.method == 'connect'), hasLength(2));
    expect(transport.debugIsNonAhoyAddress, isTrue);

    // A group teardown clears the marks for a fresh session.
    transport.debugOnDisconnected();
    await Future<void>.delayed(Duration.zero);
    transport.debugHandlePeersDiscovered([printer]);
    expect(calls.where((c) => c.method == 'connect'), hasLength(3));
  });
}

void _deliverIdentity(
  WiFiDirectTransport transport,
  CryptoService signer, {
  required String uuid,
  required String shortId,
  required String displayName,
  required String key,
  required String senderIP,
}) {
  final identity = <String, dynamic>{
    'type': 'wdIdentity',
    'uuid': uuid,
    'shortId': shortId,
    'displayName': displayName,
    'publicKeyPEM': key,
    'timestamp': DateTime.now().toIso8601String(),
  };
  identity['signature'] = signer.signAnnouncement(
    uuid: uuid,
    shortId: shortId,
    displayName: displayName,
    publicKeyPEM: key,
  );
  transport.debugHandleDataReceived({
    'data': Uint8List.fromList(utf8.encode(jsonEncode(identity))),
    'senderIP': senderIP,
  });
}
