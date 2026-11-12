import 'package:flutter/foundation.dart';
import '../models/local_user.dart';
import '../services/profile/profile_service.dart';

class ProfileProvider extends ChangeNotifier {
  final ProfileService _service;

  LocalUser? _user;
  bool _isLoading = false;

  LocalUser? get user => _user;
  bool get isLoading => _isLoading;

  ProfileProvider(this._service);

  void load() {
    _user = _service.loadProfile();
    notifyListeners();
  }

  Future<void> update({
    String? username,
    String? bio,
    List<String>? interests,
    String? statusMessage,
  }) async {
    if (_user == null) return;
    _isLoading = true;
    notifyListeners();
    _user = await _service.updateProfile(
      _user!,
      username: username,
      bio: bio,
      interests: interests,
      statusMessage: statusMessage,
    );
    _isLoading = false;
    notifyListeners();
  }

  Future<void> updateAvatar() async {
    if (_user == null) return;
    _isLoading = true;
    notifyListeners();
    _user = await _service.updateAvatar(_user!);
    _isLoading = false;
    notifyListeners();
  }

  void setUser(LocalUser user) {
    _user = user;
    notifyListeners();
  }

  void clear() {
    _user = null;
    notifyListeners();
  }
}
