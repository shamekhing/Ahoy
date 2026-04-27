import '../core/enums.dart';

class PeerProfile {
  final String uuid;
  final String shortId;
  final String displayName;
  final String? bio;
  final Gender gender;
  final String? avatarBase64;
  final List<String> interests;
  final String publicKeyPEM;
  final String? statusMessage;

  const PeerProfile({
    required this.uuid,
    required this.shortId,
    required this.displayName,
    this.bio,
    required this.gender,
    this.avatarBase64,
    required this.interests,
    required this.publicKeyPEM,
    this.statusMessage,
  });

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'shortId': shortId,
        'displayName': displayName,
        'bio': bio,
        'gender': gender.name,
        'avatarBase64': avatarBase64,
        'interests': interests,
        'publicKeyPEM': publicKeyPEM,
        'statusMessage': statusMessage,
      };

  factory PeerProfile.fromJson(Map<String, dynamic> json) {
    Gender _parseGender(dynamic value) {
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

    return PeerProfile(
      uuid: json['uuid'] as String,
      shortId: json['shortId'] as String,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String?,
      gender: _parseGender(json['gender']),
      avatarBase64: json['avatarBase64'] as String?,
      interests: List<String>.from(json['interests'] as List? ?? []),
      publicKeyPEM: json['publicKeyPEM'] as String,
      statusMessage: json['statusMessage'] as String?,
    );
  }
}
