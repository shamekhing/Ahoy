import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signs and verifies payloads with the local RSA keypair', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);

    final signature = crypto.signPayload('hello');

    expect(
      crypto.verifyPayloadSignature('hello', signature, keys['publicKey']!),
      isTrue,
    );
    expect(
      crypto.verifyPayloadSignature('tampered', signature, keys['publicKey']!),
      isFalse,
    );
  });
}
