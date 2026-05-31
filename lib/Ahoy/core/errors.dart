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

class StorageError implements Exception {
  final String reason;
  const StorageError(this.reason);
  @override
  String toString() => 'StorageError: $reason';
}
