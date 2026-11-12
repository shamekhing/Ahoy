import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/discovery_provider.dart';
import '../../providers/profile_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final discovery = context.watch<DiscoveryProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            title: Text(
              'Transports',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            dense: true,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: const Text('WiFi Direct'),
            subtitle: const Text('Fast P2P connection best for media'),
            value: discovery.wifiDirectEnabled,
            onChanged: discovery.setWifiDirectEnabled,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.lan),
            title: const Text('Local Network (LAN)'),
            subtitle: const Text('Works over any shared WiFi network'),
            value: discovery.lanEnabled,
            onChanged: discovery.setLanEnabled,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.bluetooth),
            title: const Text('Bluetooth (BLE)'),
            subtitle: const Text('Works without WiFi uses more battery'),
            value: discovery.bleEnabled,
            onChanged: discovery.setBleEnabled,
          ),
          const Divider(),
          const ListTile(
            title: Text(
              'Discovery',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            dense: true,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off),
            title: const Text('Off the Grid'),
            // Say what the toggle does NOT do: scanning stays on, you can
            // still discover others (UI review #28).
            subtitle: const Text(
              'You are invisible to others but can still discover them',
            ),
            value: discovery.offGrid,
            onChanged: discovery.setOffGrid,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.block),
            title: const Text('Receive Off'),
            // Spell out the actual behavior (spec §6.2): existing
            // conversations are never cut off (UI review #28).
            subtitle: const Text(
              'Ignore chat requests from people you have not talked to before',
            ),
            value: discovery.receiveOff,
            onChanged: discovery.setReceiveOff,
          ),
          const Divider(),
          const ListTile(
            title: Text(
              'Account',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
            ),
            dense: true,
          ),
          _BiometricTile(auth: auth),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Lock'),
            subtitle: const Text(
              'Return to the sign-in screen. Your data stays on this device.',
            ),
            onTap: () => auth.lock(),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text(
              'Sign Out & Erase Data',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => _confirmSignOut(context, auth),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('Version 1.0.0'),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Ahoy',
              applicationVersion: '1.0.0',
              applicationLegalese:
                  'Offline, serverless messaging. Non-commercial use only '
                  '(see LICENSE).',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, AuthProvider auth) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Out & Erase Data'),
        content: const Text(
          'This will erase all your messages, conversations, and account data '
          'from this device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Erase & Sign Out'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final profileProvider = context.read<ProfileProvider>();
      await auth.signOut();
      if (context.mounted) profileProvider.clear();
    }
  }
}

class _BiometricTile extends StatefulWidget {
  final AuthProvider auth;
  const _BiometricTile({required this.auth});

  @override
  State<_BiometricTile> createState() => _BiometricTileState();
}

class _BiometricTileState extends State<_BiometricTile> {
  bool _available = false;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final available = await widget.auth.isBiometricAvailable;
    final enabled = await widget.auth.isBiometricEnabled;
    if (mounted) {
      setState(() {
        _available = available;
        _enabled = enabled;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // The tile no longer vanishes silently when biometrics are unavailable
    // (UI review #28): it shows a disabled state that explains why.
    if (!_available) {
      return const ListTile(
        leading: Icon(Icons.fingerprint),
        title: Text('Biometric Sign-In'),
        subtitle: Text('Not available on this device'),
        enabled: false,
      );
    }
    return SwitchListTile(
      title: const Text('Biometric Sign-In'),
      subtitle: const Text('Use fingerprint or face to sign in'),
      value: _enabled,
      onChanged: (v) async {
        if (v) {
          final ok = await widget.auth.enableBiometric();
          if (mounted) setState(() => _enabled = ok);
          return;
        } else {
          await widget.auth.disableBiometric();
        }
        if (mounted) setState(() => _enabled = v);
      },
    );
  }
}
