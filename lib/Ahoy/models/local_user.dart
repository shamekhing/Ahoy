class LocalUser {
  final String id;
  final String username;
  final String? bio;
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
    'avatarPath': avatarPath,
    'interests': interests,
    'publicKeyPEM': publicKeyPEM,
    'shortId': shortId,
    'statusMessage': statusMessage,
    'createdAt': createdAt.toIso8601String(),
    'biometricEnabled': biometricEnabled,
  };

  factory LocalUser.fromJson(Map<String, dynamic> json) {
    return LocalUser(
      id: json['id'] as String,
      username: json['username'] as String,
      bio: json['bio'] as String?,
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
