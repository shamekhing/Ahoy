import 'dart:convert';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/errors.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

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

  test('wrong envelope versions raise a format error, not a state error', () async {
    final crypto = CryptoService();
    final keys = await crypto.generateKeyPair();
    crypto.activate(keys['privateKey']!, keys['publicKey']!);

    final wrongVersion = base64.encode(
      utf8.encode(jsonEncode({'v': 99, 'ek': 'x', 'iv': 'y', 'ct': 'z'})),
    );

    expect(
      () => crypto.decryptFromPeer(wrongVersion),
      throwsA(isA<CryptoFormatError>()),
    );
  });

  test('uses RSA-OAEP with SHA-256 for hybrid key wrapping', () async {
    final sender = CryptoService();
    final recipient = CryptoService();
    final recipientKeys = await recipient.generateKeyPair();
    recipient.activate(
      recipientKeys['privateKey']!,
      recipientKeys['publicKey']!,
    );
    final senderKeys = await sender.generateKeyPair();
    sender.activate(senderKeys['privateKey']!, senderKeys['publicKey']!);

    final encrypted = sender.encryptForPeer(
      'hello with a wrapped AES key',
      recipientKeys['publicKey']!,
    );

    expect(
      recipient.decryptFromPeer(encrypted),
      'hello with a wrapped AES key',
    );

    final envelope =
        jsonDecode(utf8.decode(base64.decode(encrypted)))
            as Map<String, dynamic>;
    final encryptedKey = Uint8List.fromList(
      base64.decode(envelope['ek'] as String),
    );
    final privateKey =
        enc.RSAKeyParser().parse(recipientKeys['privateKey']!)
            as pc.RSAPrivateKey;

    final sha1Cipher = pc.OAEPEncoding.withSHA1(pc.RSAEngine())
      ..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));
    expect(() => sha1Cipher.process(encryptedKey), throwsA(anything));

    final sha256Cipher = pc.OAEPEncoding.withSHA256(pc.RSAEngine())
      ..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));
    expect(sha256Cipher.process(encryptedKey), hasLength(32));
  });
}
