import '../core/enums.dart';

class LocalUser {
  final String id;
  final String username;
  final String? bio;
  final Gender gender;
  final String? avatarPath;
  final List<String> interests;
  final String publicKeyPEM;
  final String shortId;
  final String? statusMessage;
  final DateTime createdAt;
  final bool biometricEnabled;

  const LocalUser({
    required this.id,
    required this.username,
    this.bio,
    required this.gender,
    this.avatarPath,
    required this.interests,
    required this.publicKeyPEM,
    required this.shortId,
    this.statusMessage,
    required this.createdAt,
    this.biometricEnabled = false,
  });

  LocalUser copyWith({
    String? username,
    String? bio,
    Gender? gender,
    String? avatarPath,
    List<String>? interests,
    String? publicKeyPEM,
    String? statusMessage,
    bool? biometricEnabled,
  }) {
    return LocalUser(
      id: id,
      username: username ?? this.username,
      bio: bio ?? this.bio,
      gender: gender ?? this.gender,
      avatarPath: avatarPath ?? this.avatarPath,
      interests: interests ?? this.interests,
      publicKeyPEM: publicKeyPEM ?? this.publicKeyPEM,
      shortId: shortId,
      statusMessage: statusMessage ?? this.statusMessage,
      createdAt: createdAt,
      biometricEnabled: biometricEnabled ?? this.biometricEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'bio': bio,
        'gender': gender.name,
        'avatarPath': avatarPath,
        'interests': interests,
        'publicKeyPEM': publicKeyPEM,
        'shortId': shortId,
        'statusMessage': statusMessage,
        'createdAt': createdAt.toIso8601String(),
        'biometricEnabled': biometricEnabled,
      };

  factory LocalUser.fromJson(Map<String, dynamic> json) {
    Gender parseGender(dynamic value) {
      try {
        if (value == null) return Gender.unspecified;
        if (value is String) return Gender.values.byName(value);
        // Handle old integer-based format
        if (value is int) {
          if (value >= 0 && value < Gender.values.length) {
            return Gender.values[value];
          }
        }
        return Gender.unspecified;
      } catch (e) {
        return Gender.unspecified;
      }
    }

    return LocalUser(
      id: json['id'] as String,
      username: json['username'] as String,
      bio: json['bio'] as String?,
      gender: parseGender(json['gender']),
      avatarPath: json['avatarPath'] as String?,
      interests: List<String>.from(json['interests'] as List? ?? []),
      publicKeyPEM: json['publicKeyPEM'] as String,
      shortId: json['shortId'] as String,
      statusMessage: json['statusMessage'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      biometricEnabled: json['biometricEnabled'] as bool? ?? false,
    );
  }
}
