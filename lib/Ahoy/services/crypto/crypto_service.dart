import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;
import '../../core/errors.dart';

class CryptoService {
  static const int passwordHashIterations = 310000;
  static const int legacyPasswordHashIterations = 100000;

  bool _isReady = false;
  pc.RSAPrivateKey? _privateKey;

  bool get isReady => _isReady;

  void activate(String privateKeyPEM, String publicKeyPEM) {
    _privateKey = enc.RSAKeyParser().parse(privateKeyPEM) as pc.RSAPrivateKey;
    // Parse public key to validate it; it's re-parsed on demand from the PEM string.
    enc.RSAKeyParser().parse(publicKeyPEM) as pc.RSAPublicKey;
    _isReady = true;
  }

  void deactivate() {
    _isReady = false;
    _privateKey = null;
  }

  void _assertReady() {
    if (!_isReady) throw const CryptoNotInitialized();
  }

  // --- Password hashing ---
  //
  // New passwords use PBKDF2-HMAC-SHA256 run in an isolate so the UI thread is
  // never blocked. Stored format:
  //   "pbkdf2:v2:<iterations>:<saltHex>:<dkHex>"
  //
  // The previous PBKDF2 format used 100 000 iterations:
  //   "pbkdf2:<saltHex>:<dkHex>"
  //
  // Passwords hashed before this change used SHA-256 with a 16-byte salt:
  //   "<saltHex>:<sha256Hex>"
  // Those are still verified correctly so existing accounts keep working.

  Future<String> hashPassword(String password) async {
    final salt = _randomBytes(16);
    final saltHex = _bytesToHex(salt);
    final dkHex = await Isolate.run(
      () => _pbkdf2Hex(saltHex, password, passwordHashIterations),
    );
    return 'pbkdf2:v2:$passwordHashIterations:$saltHex:$dkHex';
  }

  Future<bool> verifyPassword(String password, String storedHash) async {
    if (storedHash.startsWith('pbkdf2:v2:')) {
      final parts = storedHash.split(':');
      if (parts.length != 5) return false;
      final iterations = int.tryParse(parts[2]);
      if (iterations == null || iterations <= 0) return false;
      final saltHex = parts[3];
      final expectedDkHex = parts[4];
      final dkHex = await Isolate.run(
        () => _pbkdf2Hex(saltHex, password, iterations),
      );
      return _constantTimeEquals(dkHex, expectedDkHex);
    }

    if (storedHash.startsWith('pbkdf2:')) {
      final parts = storedHash.split(':');
      if (parts.length != 3) return false;
      final saltHex = parts[1];
      final expectedDkHex = parts[2];
      final dkHex = await Isolate.run(
        () => _pbkdf2Hex(saltHex, password, legacyPasswordHashIterations),
      );
      return _constantTimeEquals(dkHex, expectedDkHex);
    }
    // Legacy SHA-256 format — verify without blocking the UI (fast).
    final parts = storedHash.split(':');
    if (parts.length != 2) return false;
    final hash = sha256.convert(utf8.encode(parts[0] + password));
    return _constantTimeEquals(hash.toString(), parts[1]);
  }

  bool passwordHashNeedsUpgrade(String storedHash) {
    if (storedHash.startsWith('pbkdf2:v2:')) {
      final parts = storedHash.split(':');
      if (parts.length != 5) return true;
      final iterations = int.tryParse(parts[2]);
      return iterations == null || iterations < passwordHashIterations;
    }
    return true;
  }

  /// Constant-time string comparison to prevent timing attacks.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  // --- RSA key generation (runs in a separate isolate — never blocks UI) ---

  Future<Map<String, String>> generateKeyPair() async {
    return Isolate.run(_generateKeyPairInIsolate);
  }

  // --- E2E hybrid encryption: RSA-OAEP wraps a per-message AES-256-GCM key ---
  //
  // Envelope (v=2): { v:2, ek:<RSA-OAEP(aesKey) in base64>, iv:<12 bytes in base64>, ct:<AES-GCM ciphertext in base64> }
  // Whole envelope is base64(utf8(jsonEncode(envelope))).
  //
  // encryptForPeer requires the peer's public key.
  // decryptFromPeer uses this device's loaded private key.

  String encryptForPeer(String plaintext, String peerPublicKeyPEM) {
    _assertReady();
    final peerPublicKey =
        enc.RSAKeyParser().parse(peerPublicKeyPEM) as pc.RSAPublicKey;
    final aesKey = _randomBytes(32);
    final iv = enc.IV(_randomBytes(12));
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(aesKey), mode: enc.AESMode.gcm),
    );
    final ct = encrypter.encrypt(plaintext, iv: iv);
    final encryptedKey = _rsaOaepEncrypt(aesKey, peerPublicKey);
    return base64.encode(
      utf8.encode(
        jsonEncode({
          'v': 2,
          'ek': base64.encode(encryptedKey),
          'iv': base64.encode(iv.bytes),
          'ct': ct.base64,
        }),
      ),
    );
  }

  String decryptFromPeer(String encryptedBase64) {
    _assertReady();
    final envelope =
        jsonDecode(utf8.decode(base64.decode(encryptedBase64))) as Map;
    if (envelope['v'] != 2) throw const CryptoNotInitialized();
    final encryptedKey = base64.decode(envelope['ek'] as String);
    final aesKey = _rsaOaepDecrypt(encryptedKey);
    final iv = enc.IV(base64.decode(envelope['iv'] as String));
    final ct = enc.Encrypted.fromBase64(envelope['ct'] as String);
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(aesKey), mode: enc.AESMode.gcm),
    );
    return encrypter.decrypt(ct, iv: iv);
  }

  String signPayload(String payload) {
    _assertReady();
    final signer = pc.Signer('SHA-256/RSA')
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(_privateKey!));
    final signature =
        signer.generateSignature(Uint8List.fromList(utf8.encode(payload)))
            as pc.RSASignature;
    return base64.encode(signature.bytes);
  }

  bool verifyPayloadSignature(
    String payload,
    String signatureBase64,
    String publicKeyPEM,
  ) {
    try {
      final publicKey =
          enc.RSAKeyParser().parse(publicKeyPEM) as pc.RSAPublicKey;
      final verifier = pc.Signer('SHA-256/RSA')
        ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));
      final signature = pc.RSASignature(base64.decode(signatureBase64));
      return verifier.verifySignature(
        Uint8List.fromList(utf8.encode(payload)),
        signature,
      );
    } catch (_) {
      return false;
    }
  }

  // --- Identity binding (audit H-2) ---

  /// Canonical JSON string binding an announced identity to a public key.
  /// Both sides must derive identical material — keep the field set frozen.
  static String announcementMaterial({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  }) {
    return jsonEncode({
      'uuid': uuid,
      'shortId': shortId,
      'displayName': displayName,
      'statusMessage': statusMessage,
      'publicKeyPEM': publicKeyPEM,
    });
  }

  /// Signs an identity announcement with the loaded private key, binding
  /// (uuid, shortId, displayName) to [publicKeyPEM].
  String signAnnouncement({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
  }) {
    return signPayload(
      announcementMaterial(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
      ),
    );
  }

  /// Verifies that an announcement legitimately binds (uuid, shortId,
  /// displayName) to [publicKeyPEM] — i.e. the announcer controls the private
  /// key for the identity they claim.
  bool verifyAnnouncement({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    required String publicKeyPEM,
    required String signature,
  }) {
    return verifyPayloadSignature(
      announcementMaterial(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: publicKeyPEM,
      ),
      signature,
      publicKeyPEM,
    );
  }

  /// 60-digit safety number (12 groups of 5 digits, Signal-style) derived
  /// from the canonical form of a public key. Identical on both devices for
  /// the same key pair — users compare it out-of-band to detect impersonation.
  static String fingerprintFromPublicKey(String publicKeyPEM) {
    final canonical = publicKeyPEM.replaceAll(RegExp(r'\s+'), '');
    final hash = sha256.convert(utf8.encode(canonical)).toString();
    final bits = BigInt.parse(hash.substring(0, 51), radix: 16); // 204 bits
    final groups = List.generate(12, (i) {
      final shift = 187 - 17 * i; // 12 chunks of 17 bits
      final value = ((bits >> shift) & BigInt.from(0x1FFFF)).toInt();
      return (value % 100000).toString().padLeft(5, '0');
    });
    return groups.join(' ');
  }

  // --- Utilities ---

  static String shortIdFromUuid(String uuid) {
    final hash = sha256.convert(utf8.encode(uuid));
    final num = int.parse(hash.toString().substring(0, 12), radix: 16);
    return num.toRadixString(36).padLeft(6, '0').substring(0, 6).toUpperCase();
  }

  static String conversationId(String myUuid, String peerUuid) {
    final sorted = [myUuid, peerUuid]..sort();
    return sha256
        .convert(utf8.encode('${sorted[0]}:${sorted[1]}'))
        .toString()
        .substring(0, 32);
  }

  Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _rsaOaepEncrypt(Uint8List data, pc.RSAPublicKey publicKey) {
    final cipher = pc.OAEPEncoding.withSHA256(pc.RSAEngine())
      ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));
    return cipher.process(data);
  }

  Uint8List _rsaOaepDecrypt(Uint8List data) {
    final cipher = pc.OAEPEncoding.withSHA256(pc.RSAEngine())
      ..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(_privateKey!));
    return cipher.process(data);
  }
}

// ── PBKDF2 (top-level so it can run in an isolate) ────────────────────────

/// Derives a 32-byte key from [password] and [saltHex] using PBKDF2-HMAC-SHA256
/// and returns the result as a lowercase hex string.
String _pbkdf2Hex(String saltHex, String password, int iterations) {
  final saltBytes = Uint8List.fromList([
    for (var i = 0; i < saltHex.length; i += 2)
      int.parse(saltHex.substring(i, i + 2), radix: 16),
  ]);
  final passwordBytes = utf8.encode(password);

  final params = pc.Pbkdf2Parameters(saltBytes, iterations, 32);
  final kdf = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
    ..init(params);
  final dk = kdf.process(Uint8List.fromList(passwordBytes));
  return dk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// Top-level function — required for Isolate.run / compute.
Map<String, String> _generateKeyPairInIsolate() {
  final secureRandom = pc.SecureRandom('Fortuna')
    ..seed(
      pc.KeyParameter(
        Uint8List.fromList(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ),
    );

  final keyGen = pc.RSAKeyGenerator()
    ..init(
      pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        secureRandom,
      ),
    );

  final pair = keyGen.generateKeyPair();
  final pub = pair.publicKey as pc.RSAPublicKey;
  final priv = pair.privateKey as pc.RSAPrivateKey;

  return {
    'publicKey': _encodePublicKey(pub),
    'privateKey': _encodePrivateKey(priv),
  };
}

// ── DER helpers (no pointycastle ASN1 API — avoids RangeError in v3.x) ────

Uint8List _bigIntToDerBytes(BigInt v) {
  if (v == BigInt.zero) return Uint8List.fromList([0x00]);
  final hex = v.toRadixString(16);
  final padded = hex.length.isOdd ? '0$hex' : hex;
  final bytes = <int>[];
  for (var i = 0; i < padded.length; i += 2) {
    bytes.add(int.parse(padded.substring(i, i + 2), radix: 16));
  }
  if (bytes[0] & 0x80 != 0) bytes.insert(0, 0x00);
  return Uint8List.fromList(bytes);
}

List<int> _derLen(int len) {
  if (len < 0x80) return [len];
  if (len < 0x100) return [0x81, len];
  return [0x82, (len >> 8) & 0xff, len & 0xff];
}

Uint8List _derInt(BigInt v) {
  final body = _bigIntToDerBytes(v);
  return Uint8List.fromList([0x02, ..._derLen(body.length), ...body]);
}

Uint8List _derSeq(List<Uint8List> parts) {
  final body = parts.expand((p) => p).toList();
  return Uint8List.fromList([0x30, ..._derLen(body.length), ...body]);
}

String _wrapPem(String b64) {
  final sb = StringBuffer();
  for (var i = 0; i < b64.length; i += 64) {
    sb.writeln(b64.substring(i, (i + 64).clamp(0, b64.length)));
  }
  return sb.toString().trimRight();
}

String _encodePublicKey(pc.RSAPublicKey key) {
  final der = _derSeq([_derInt(key.modulus!), _derInt(key.publicExponent!)]);
  return '-----BEGIN RSA PUBLIC KEY-----\n${_wrapPem(base64.encode(der))}\n-----END RSA PUBLIC KEY-----';
}

String _encodePrivateKey(pc.RSAPrivateKey key) {
  final d = key.privateExponent!;
  final p = key.p!;
  final q = key.q!;
  final der = _derSeq([
    _derInt(BigInt.zero),
    _derInt(key.modulus!),
    _derInt(key.publicExponent!),
    _derInt(d),
    _derInt(p),
    _derInt(q),
    _derInt(d % (p - BigInt.one)),
    _derInt(d % (q - BigInt.one)),
    _derInt(q.modInverse(p)),
  ]);
  return '-----BEGIN RSA PRIVATE KEY-----\n${_wrapPem(base64.encode(der))}\n-----END RSA PRIVATE KEY-----';
}
