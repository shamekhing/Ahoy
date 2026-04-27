import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/constants.dart';
import '../../models/local_user.dart';
import '../../core/enums.dart';
import '../storage/prefs_store.dart';

class ProfileService {
  final PrefsStore _prefsStore;

  ProfileService(this._prefsStore);

  LocalUser? loadProfile() {
    final json = _prefsStore.getJson(AhoyConstants.prefProfile);
    if (json == null) return null;
    return LocalUser.fromJson(json);
  }

  Future<void> saveProfile(LocalUser user) async {
    await _prefsStore.setJson(AhoyConstants.prefProfile, user.toJson());
  }

  Future<LocalUser> updateProfile(
    LocalUser current, {
    String? username,
    String? bio,
    Gender? gender,
    List<String>? interests,
    String? statusMessage,
  }) async {
    final updated = current.copyWith(
      username: username,
      bio: bio,
      gender: gender,
      interests: interests,
      statusMessage: statusMessage,
    );
    await saveProfile(updated);
    return updated;
  }

  Future<LocalUser> updateAvatar(LocalUser current) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (picked == null) return current;

    final appDir = await getApplicationDocumentsDirectory();
    final destPath = '${appDir.path}/avatar_${current.id}.jpg';
    await File(picked.path).copy(destPath);

    final updated = current.copyWith(avatarPath: destPath);
    await saveProfile(updated);
    return updated;
  }

  /// Encode a small version of avatar to base64 for over-the-air broadcast.
  Future<String?> avatarBase64(LocalUser user) async {
    if (user.avatarPath == null) return null;
    final file = File(user.avatarPath!);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    // Keep broadcast payload small — 40KB max
    if (bytes.length > 40960) return null;
    return base64.encode(bytes);
  }

  String defaultAvatarAsset(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'assets/avatars/male.png';
      case Gender.female:
        return 'assets/avatars/female.png';
      case Gender.unspecified:
        return 'assets/avatars/neutral.png';
    }
  }
}
