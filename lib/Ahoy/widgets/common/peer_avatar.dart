import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/enums.dart';

class PeerAvatar extends StatelessWidget {
  final String? avatarPath;
  final String? avatarBase64;
  final Gender gender;
  final double radius;

  const PeerAvatar({
    super.key,
    this.avatarPath,
    this.avatarBase64,
    required this.gender,
    this.radius = 24,
  });

  @override
  Widget build(BuildContext context) {
    ImageProvider? image;

    if (avatarPath != null && File(avatarPath!).existsSync()) {
      image = FileImage(File(avatarPath!));
    } else if (avatarBase64 != null && avatarBase64!.isNotEmpty) {
      try {
        image = MemoryImage(base64.decode(avatarBase64!));
      } catch (_) {}
    }

    if (image != null) {
      return CircleAvatar(radius: radius, backgroundImage: image);
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: _bgColor,
      child: Icon(_icon, color: Colors.white, size: radius),
    );
  }

  Color get _bgColor => switch (gender) {
        Gender.male => Colors.blue.shade400,
        Gender.female => Colors.pink.shade400,
        Gender.unspecified => Colors.purple.shade400,
      };

  IconData get _icon => switch (gender) {
        Gender.male => Icons.person,
        Gender.female => Icons.person_2,
        Gender.unspecified => Icons.person_outline,
      };
}
