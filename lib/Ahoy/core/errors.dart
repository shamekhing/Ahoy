class CryptoNotInitialized implements Exception {
  const CryptoNotInitialized();
  @override
  String toString() =>
      'CryptoService has not been activated. Call KeyStore.load() first.';
}

class AuthFailed implements Exception {
  final String reason;
  const AuthFailed(this.reason);
  @override
  String toString() => 'AuthFailed: $reason';
}

class TransportError implements Exception {
  final String reason;
  const TransportError(this.reason);
  @override
  String toString() => 'TransportError: $reason';
}

/// Thrown when a crypto envelope is malformed or from an unsupported
/// protocol version — distinct from [CryptoNotInitialized], which means the
/// key material has not been loaded yet.
class CryptoFormatError implements Exception {
  final String reason;
  const CryptoFormatError(this.reason);
  @override
  String toString() => 'CryptoFormatError: $reason';
}

class StorageError implements Exception {
  final String reason;
  const StorageError(this.reason);
  @override
  String toString() => 'StorageError: $reason';
}
