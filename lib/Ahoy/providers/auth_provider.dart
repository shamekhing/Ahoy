import 'package:flutter/foundation.dart';
import '../models/local_user.dart';
import '../core/enums.dart';
import '../services/auth/auth_service.dart';
import '../services/transport_manager.dart';

enum AuthState { unknown, signedOut, signedIn }

class AuthProvider extends ChangeNotifier {
  final AuthService _authService;
  final TransportManager _transport;

  AuthState _state = AuthState.unknown;
  LocalUser? _user;
  String? _error;

  AuthState get state => _state;
  LocalUser? get user => _user;
  String? get error => _error;
  bool get isSignedIn => _state == AuthState.signedIn;

  AuthProvider(this._authService, this._transport);

  Future<void> checkSession() async {
    final signedIn = await _authService.isSignedIn;
    _state = signedIn ? AuthState.signedIn : AuthState.signedOut;
    notifyListeners();
  }

  Future<bool> signUp({
    required String username,
    required String password,
    required Gender gender,
    List<String> interests = const [],
    String? bio,
  }) async {
    _error = null;
    notifyListeners();
    try {
      _user = await _authService.signUp(
        username: username,
        password: password,
        gender: gender,
        interests: interests,
        bio: bio,
      );
      _state = AuthState.signedIn;
      notifyListeners();
      return true;
    } catch (e) {
      _error = _clean(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> signIn({required String password}) async {
    _error = null;
    notifyListeners();
    try {
      _user = await _authService.signIn(password: password);
      _state = AuthState.signedIn;
      notifyListeners();
      return true;
    } catch (e) {
      _error = _clean(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> signInWithBiometric() async {
    _error = null;
    try {
      final user = await _authService.signInWithBiometric();
      if (user == null) return false;
      _user = user;
      _state = AuthState.signedIn;
      notifyListeners();
      return true;
    } catch (e) {
      _error = _clean(e);
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    // Awaits transport shutdown before wiping storage.
    await _authService.signOut(onTransportStop: () => _transport.stopAll());
    _user = null;
    _state = AuthState.signedOut;
    _error = null;
    notifyListeners();
  }

  Future<bool> get isBiometricAvailable => _authService.isBiometricAvailable;
  Future<bool> get isBiometricEnabled => _authService.isBiometricEnabled;

  Future<void> enableBiometric() async {
    await _authService.enableBiometric();
  }

  void updateUser(LocalUser user) {
    _user = user;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  String _clean(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('AuthFailed: ', '');
}
