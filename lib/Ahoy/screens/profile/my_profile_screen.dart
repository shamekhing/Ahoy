import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/profile_provider.dart';
import '../../core/constants.dart';
import '../../services/crypto/crypto_service.dart';
import '../../services/crypto/local_data_crypto.dart';
import '../../services/transport_manager.dart';
import '../../widgets/common/peer_avatar.dart';

class MyProfileScreen extends StatelessWidget {
  const MyProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileProvider>();
    final auth = context.watch<AuthProvider>();
    final user = profile.user ?? auth.user;

    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const _EditProfileScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Lock',
            onPressed: () => _lock(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Stack(
              children: [
                PeerAvatar(
                  avatarPath: user.avatarPath,
                  name: user.username,
                  shortId: user.shortId,
                  radius: 48,
                  localDataCrypto: context.read<LocalDataCrypto>(),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: InkWell(
                    onTap: () => context.read<ProfileProvider>().updateAvatar(),
                    child: const CircleAvatar(
                      radius: 14,
                      child: Icon(Icons.camera_alt, size: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              user.username,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Center(
            child: Text(
              '@${user.shortId}',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Safety number',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            CryptoService.fingerprintFromPublicKey(user.publicKeyPEM),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'This is your key fingerprint peers see the same number on '
            'your profile card. Open a peer\'s profile to compare your '
            'per-conversation safety number.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          if (user.statusMessage != null && user.statusMessage!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                '"${user.statusMessage}"',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.grey,
                ),
              ),
            ),
          ],
          if (user.bio != null && user.bio!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(user.bio!, textAlign: TextAlign.center),
          ],
          if (user.interests.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Interests',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: user.interests
                  .map(
                    (i) => Chip(
                      label: Text(i),
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 32),
          OutlinedButton.icon(
            icon: const Icon(Icons.lock_outline),
            label: const Text('Lock'),
            onPressed: () => _lock(context),
          ),
        ],
      ),
    );
  }

  /// Locks the session (UI review #5): non-destructive, the data stays on
  /// the device and unlocking is the normal sign-in flow.
  Future<void> _lock(BuildContext context) async {
    await context.read<AuthProvider>().lock();
  }
}

class _EditProfileScreen extends StatefulWidget {
  const _EditProfileScreen();

  @override
  State<_EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<_EditProfileScreen> {
  late TextEditingController _usernameCtrl;
  late TextEditingController _bioCtrl;
  late TextEditingController _statusCtrl;
  late List<String> _interests;
  bool _loading = false;

  static const _interestOptions = [
    'Music',
    'Tech',
    'Sports',
    'Food',
    'Travel',
    'Art',
    'Gaming',
    'Reading',
    'Fitness',
    'Nature',
  ];

  @override
  void initState() {
    super.initState();
    final user =
        context.read<ProfileProvider>().user ??
        context.read<AuthProvider>().user!;
    _usernameCtrl = TextEditingController(text: user.username);
    _bioCtrl = TextEditingController(text: user.bio ?? '');
    _statusCtrl = TextEditingController(text: user.statusMessage ?? '');
    _interests = List.from(user.interests);
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _bioCtrl.dispose();
    _statusCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    final profile = context.read<ProfileProvider>();
    await profile.update(
      username: _usernameCtrl.text.trim(),
      bio: _bioCtrl.text.trim().isEmpty ? null : _bioCtrl.text.trim(),
      interests: _interests,
      statusMessage: _statusCtrl.text.trim().isEmpty
          ? null
          : _statusCtrl.text.trim(),
    );
    if (!mounted) return;

    final user = profile.user;
    if (user != null) {
      // Keep AuthProvider in sync so outgoing messages use the new display name.
      context.read<AuthProvider>().updateUser(user);
      // Keep the chat layer's sender identity in sync so identity replies
      // carry the new name too (audit L-7).
      context.read<ChatProvider>().updateMyIdentity(
            myShortId: user.shortId,
            myDisplayName: user.username,
            myPublicKeyPEM: user.publicKeyPEM,
          );
      // Re-advertise so nearby peers see the updated name and status
      // immediately. refreshAdvertising() is a no-op while Off the Grid is
      // on, so a profile edit cannot broadcast a hidden identity (audit H-3).
      try {
        await context.read<TransportManager>().refreshAdvertising();
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _loading = false);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _loading ? null : _save,
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextFormField(
            controller: _usernameCtrl,
            decoration: const InputDecoration(
              labelText: 'Display Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _bioCtrl,
            decoration: const InputDecoration(
              labelText: 'Bio',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
            maxLength: AhoyConstants.maxBioLength,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _statusCtrl,
            decoration: const InputDecoration(
              labelText: 'Status (shown in Discover)',
              hintText: 'e.g. Looking for coffee',
              border: OutlineInputBorder(),
            ),
            maxLength: AhoyConstants.maxStatusLength,
          ),
          const SizedBox(height: 8),
          const SizedBox(height: 16),
          const Text(
            'Interests',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _interestOptions.map((interest) {
              final selected = _interests.contains(interest);
              return FilterChip(
                label: Text(interest),
                selected: selected,
                onSelected: (v) => setState(() {
                  if (v) {
                    _interests.add(interest);
                  } else {
                    _interests.remove(interest);
                  }
                }),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
