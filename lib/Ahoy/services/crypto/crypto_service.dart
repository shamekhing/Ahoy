import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;
import '../../core/errors.dart';

class CryptoService {
  bool _isReady = false;

  bool get isReady => _isReady;

  void activate(String privateKeyPEM, String publicKeyPEM) {
    enc.RSAKeyParser().parse(privateKeyPEM) as pc.RSAPrivateKey;
    enc.RSAKeyParser().parse(publicKeyPEM) as pc.RSAPublicKey;
    _isReady = true;
  }

  void deactivate() {
    _isReady = false;
  }

  void _assertReady() {
    if (!_isReady) throw const CryptoNotInitialized();
  }

  // --- Password hashing (fast — stays on main thread) ---

  String hashPassword(String password) {
    final salt = _randomBytes(16);
    final saltHex = _bytesToHex(salt);
    final hash = sha256.convert(utf8.encode(saltHex + password));
    return '$saltHex:${hash.toString()}';
  }

  bool verifyPassword(String password, String storedHash) {
    final parts = storedHash.split(':');
    if (parts.length != 2) return false;
    final hash = sha256.convert(utf8.encode(parts[0] + password));
    return hash.toString() == parts[1];
  }

  // --- RSA key generation (runs in a separate isolate — never blocks UI) ---

  Future<Map<String, String>> generateKeyPair() async {
    return Isolate.run(_generateKeyPairInIsolate);
  }

  // --- AES-GCM message encryption ---

  String encryptMessage(String plaintext) {
    _assertReady();
    final key = enc.Key(_randomBytes(32));
    final iv = enc.IV(_randomBytes(12));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final envelope = {
      'k': base64.encode(key.bytes),
      'iv': base64.encode(iv.bytes),
      'ct': encrypted.base64,
    };
    return base64.encode(utf8.encode(jsonEncode(envelope)));
  }

  String decryptMessage(String encryptedBase64) {
    _assertReady();
    final envelope = jsonDecode(utf8.decode(base64.decode(encryptedBase64))) as Map;
    final key = enc.Key(base64.decode(envelope['k'] as String));
    final iv = enc.IV(base64.decode(envelope['iv'] as String));
    final ct = enc.Encrypted.fromBase64(envelope['ct'] as String);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    return encrypter.decrypt(ct, iv: iv);
  }

  // --- Utilities ---

  static String shortIdFromUuid(String uuid) {
    final hash = sha256.convert(utf8.encode(uuid));
    final num = int.parse(hash.toString().substring(0, 12), radix: 16);
    return num.toRadixString(36).padLeft(6, '0').substring(0, 6).toUpperCase();
  }

  static String conversationId(String myUuid, String peerUuid) {
    final sorted = [myUuid, peerUuid]..sort();
    return sha256.convert(utf8.encode('${sorted[0]}:${sorted[1]}')).toString().substring(0, 32);
  }

  Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// Top-level function — required for Isolate.run / compute.
Map<String, String> _generateKeyPairInIsolate() {
  final secureRandom = pc.SecureRandom('Fortuna')
    ..seed(pc.KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)))));

  final keyGen = pc.RSAKeyGenerator()
    ..init(pc.ParametersWithRandom(
      pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
      secureRandom,
    ));

  final pair = keyGen.generateKeyPair();
  final pub = pair.publicKey as pc.RSAPublicKey;
  final priv = pair.privateKey as pc.RSAPrivateKey;

  return {
    'publicKey': _encodePublicKey(pub),
    'privateKey': _encodePrivateKey(priv),
  };
}

// ── DER helpers (no pointycastle ASN1 API — avoids RangeError in v3.x) ────

/// Convert a non-negative BigInt to its minimal big-endian unsigned byte array,
/// prefixed with 0x00 when the high bit is set (DER INTEGER sign convention).
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

// PKCS#1 RSAPublicKey  →  "-----BEGIN RSA PUBLIC KEY-----"
// (encrypt's RSAKeyParser recognises this header + PKCS#1 content)
String _encodePublicKey(pc.RSAPublicKey key) {
  final der = _derSeq([_derInt(key.modulus!), _derInt(key.publicExponent!)]);
  return '-----BEGIN RSA PUBLIC KEY-----\n${_wrapPem(base64.encode(der))}\n-----END RSA PUBLIC KEY-----';
}

// PKCS#1 RSAPrivateKey  →  "-----BEGIN RSA PRIVATE KEY-----"
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
