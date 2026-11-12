import 'dart:convert';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/transport/wifi_direct_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const _peerUuid = '22222222-2222-4222-8222-222222222222';

/// Spec §8.2: the WiFi Direct UUID→key binding survives group teardown and
/// is cleared only on sign-out (accepted in PROTOCOL.md §13).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the verified key binding survives transport teardown', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);

    final transport = WiFiDirectTransport(crypto: crypto);
    addTearDown(transport.dispose);

    final ts = DateTime.now().toIso8601String();
    final identity = {
      'type': 'wdIdentity',
      'uuid': _peerUuid,
      'shortId': CryptoService.shortIdFromUuid(_peerUuid),
      'displayName': 'Peer',
      'statusMessage': null,
      'publicKeyPEM': keys['publicKey'],
      'signature': crypto.signAnnouncement(
        uuid: _peerUuid,
        shortId: CryptoService.shortIdFromUuid(_peerUuid),
        displayName: 'Peer',
        statusMessage: null,
        publicKeyPEM: keys['publicKey'],
        timestamp: ts,
      ),
      'timestamp': ts,
    };
    transport.debugHandleDataReceived({
      'data': Uint8List.fromList(utf8.encode(jsonEncode(identity))),
      'senderIP': '192.168.43.5',
    });

    expect(transport.debugUuidKeys[_peerUuid], keys['publicKey']);

    // Teardown: the group dissolves, routing state goes with it, but the
    // key binding is process-lifetime by design.
    await transport.dispose();
    expect(transport.debugUuidKeys[_peerUuid], keys['publicKey']);
  });

  test('a later identity with a different key is refused after teardown',
      () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);

    final transport = WiFiDirectTransport(crypto: crypto);
    addTearDown(transport.dispose);

    Map<String, dynamic> identity(CryptoService signer, String pem) {
      final ts = DateTime.now().toIso8601String();
      return {
        'type': 'wdIdentity',
        'uuid': _peerUuid,
        'shortId': CryptoService.shortIdFromUuid(_peerUuid),
        'displayName': 'Peer',
        'statusMessage': null,
        'publicKeyPEM': pem,
        'signature': signer.signAnnouncement(
          uuid: _peerUuid,
          shortId: CryptoService.shortIdFromUuid(_peerUuid),
          displayName: 'Peer',
          statusMessage: null,
          publicKeyPEM: pem,
          timestamp: ts,
        ),
        'timestamp': ts,
      };
    }

    transport.debugHandleDataReceived({
      'data': Uint8List.fromList(
        utf8.encode(jsonEncode(identity(crypto, keys['publicKey']!))),
      ),
      'senderIP': '192.168.43.5',
    });
    await transport.dispose();

    // A second identity for the same UUID with a different key arrives
    // after the group reformed: refused, first key stays.
    final impostor = CryptoService();
    final impostorKeys = await impostor.generateKeyPair();
    impostor.activate(impostorKeys['privateKey']!, impostorKeys['publicKey']!);
    transport.debugHandleDataReceived({
      'data': Uint8List.fromList(
        utf8.encode(
          jsonEncode(identity(impostor, impostorKeys['publicKey']!)),
        ),
      ),
      'senderIP': '192.168.43.9',
    });

    expect(transport.debugUuidKeys[_peerUuid], keys['publicKey']);
  });
}
