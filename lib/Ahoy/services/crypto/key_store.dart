import '../storage/secure_store.dart';
import 'crypto_service.dart';
import '../../core/constants.dart';

class KeyStore {
  final SecureStore _secureStore;
  final CryptoService _cryptoService;

  KeyStore(this._secureStore, this._cryptoService);

  Future<void> load() async {
    final privateKey = await _secureStore.read(AhoyConstants.keyPrivateKey);
    final publicKey = await _secureStore.read(AhoyConstants.keyPublicKey);
    if (privateKey == null || publicKey == null) {
      throw StateError('No keypair in storage. User must sign up first.');
    }
    _cryptoService.activate(privateKey, publicKey);
  }

  Future<void> save(String privateKeyPEM, String publicKeyPEM) async {
    await _secureStore.write(AhoyConstants.keyPrivateKey, privateKeyPEM);
    await _secureStore.write(AhoyConstants.keyPublicKey, publicKeyPEM);
  }

  Future<void> clear() async {
    await _secureStore.delete(AhoyConstants.keyPrivateKey);
    await _secureStore.delete(AhoyConstants.keyPublicKey);
    _cryptoService.deactivate();
  }
}
