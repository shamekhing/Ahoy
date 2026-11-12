import 'dart:convert';
import 'dart:io';

import 'package:ahoy/Ahoy/services/chat/message_store.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Appendix B golden vectors (PROTOCOL.md). The fixture key is a dedicated
/// 2048-bit RSA test key under test/fixtures/ — never a production key.
/// RSA PKCS#1 v1.5 signatures are deterministic, so these vectors are
/// reproducible by any conforming implementation.
void main() {
  const uuidA = '11111111-1111-4111-8111-111111111111';
  const uuidB = '22222222-2222-4222-8222-222222222222';
  const timestamp = '2026-01-01T00:00:00.000Z';

  late CryptoService crypto;
  late Map<String, dynamic> golden;
  late String publicKeyPEM;
  late String publicKeyB;

  setUpAll(() async {
    crypto = CryptoService();
    final privatePEM = await File(
      'test/fixtures/ahoy_test_key.pem',
    ).readAsString();
    publicKeyPEM = await File(
      'test/fixtures/ahoy_test_key_pub.pem',
    ).readAsString();
    publicKeyB = await File(
      'test/fixtures/ahoy_test_key_b_pub.pem',
    ).readAsString();
    crypto.activate(privatePEM.trim(), publicKeyPEM.trim());
    golden =
        jsonDecode(await File('test/fixtures/golden_vectors.json').readAsString())
            as Map<String, dynamic>;
  });

  test('derived identifiers match the recorded vectors', () {
    expect(CryptoService.shortIdFromUuid(uuidA), golden['shortIdA']);
    expect(CryptoService.shortIdFromUuid(uuidB), golden['shortIdB']);
    expect(
      MessageStore.conversationId(uuidA, uuidB),
      golden['conversationId'],
    );
    expect(
      CryptoService.fingerprintFromPublicKey(publicKeyPEM.trim()),
      golden['fingerprint'],
    );
    expect(
      CryptoService.safetyNumberFor(publicKeyPEM.trim(), publicKeyB.trim()),
      golden['safetyNumber'],
    );
  });

  test('signed materials reproduce byte-for-byte', () {
    final announceMaterial = 'ahoy-announce-v1:${jsonEncode({
      'uuid': uuidB,
      'shortId': CryptoService.shortIdFromUuid(uuidB),
      'displayName': 'Peer',
      'statusMessage': null,
      'publicKeyPEM': publicKeyPEM.trim(),
      'timestamp': timestamp,
    })}';
    expect(announceMaterial, golden['announceMaterial']);

    final chatMaterial = 'ahoy-chat-v3:${jsonEncode({
      'msgType': 'chat',
      'msgId': 'aaaaaaaa-1111-2222-3333-444444444444',
      'convId': MessageStore.conversationId(uuidA, uuidB),
      'senderUuid': uuidB,
      'senderShortId': CryptoService.shortIdFromUuid(uuidB),
      'senderName': 'Peer',
      'type': 'text',
      'content': 'hello',
      'replyToId': null,
      'replyToPreview': null,
      'timestamp': timestamp,
      'senderPublicKeyPEM': publicKeyPEM.trim(),
    })}';
    expect(chatMaterial, golden['chatMaterial']);

    final ackMaterial = 'ahoy-ack-v1:${jsonEncode({
      'msgType': 'ack',
      'ackFor': 'aaaaaaaa-1111-2222-3333-444444444444',
      'convId': MessageStore.conversationId(uuidA, uuidB),
      'senderUuid': uuidB,
      'timestamp': timestamp,
    })}';
    expect(ackMaterial, golden['ackMaterial']);

    final identityMaterial = 'ahoy-identity-v1:${jsonEncode({
      'msgType': 'identity',
      'senderUuid': uuidB,
      'senderShortId': CryptoService.shortIdFromUuid(uuidB),
      'senderName': 'Peer',
      'senderPublicKeyPEM': publicKeyPEM.trim(),
      'timestamp': timestamp,
    })}';
    expect(identityMaterial, golden['identityMaterial']);
  });

  test('fixture-key signatures are deterministic and verify', () {
    expect(
      crypto.signPayload(golden['chatMaterial'] as String),
      golden['chatSignature'],
    );
    expect(
      crypto.signPayload(golden['ackMaterial'] as String),
      golden['ackSignature'],
    );
    expect(
      crypto.signPayload(golden['identityMaterial'] as String),
      golden['identitySignature'],
    );
    expect(
      crypto.signAnnouncement(
        uuid: uuidB,
        shortId: CryptoService.shortIdFromUuid(uuidB),
        displayName: 'Peer',
        statusMessage: null,
        publicKeyPEM: publicKeyPEM.trim(),
        timestamp: timestamp,
      ),
      golden['announceSignature'],
    );
    expect(
      crypto.verifyPayloadSignature(
        golden['chatMaterial'] as String,
        golden['chatSignature'] as String,
        publicKeyPEM.trim(),
      ),
      isTrue,
    );
    expect(
      crypto.verifyAnnouncement(
        uuid: uuidB,
        shortId: CryptoService.shortIdFromUuid(uuidB),
        displayName: 'Peer',
        statusMessage: null,
        publicKeyPEM: publicKeyPEM.trim(),
        signature: golden['announceSignature'] as String,
        timestamp: timestamp,
      ),
      isTrue,
    );
  });

  test('PROTOCOL.md Appendix B records the same compact vectors', () async {
    final doc = await File('PROTOCOL.md').readAsString();
    expect(doc, contains(golden['shortIdA'] as String));
    expect(doc, contains(golden['conversationId'] as String));
    expect(doc, contains(golden['fingerprint'] as String));
    expect(doc, contains(golden['safetyNumber'] as String));
  });
}
