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
            title: Text('Transports', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            dense: true,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: const Text('WiFi Direct'),
            subtitle: const Text('Fast P2P connection — best for media'),
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
            subtitle: const Text('Works without WiFi — uses more battery'),
            value: discovery.bleEnabled,
            onChanged: discovery.setBleEnabled,
          ),
          const Divider(),
          const ListTile(
            title: Text('Discovery', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            dense: true,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off),
            title: const Text('Off the Grid'),
            subtitle: const Text('Stop broadcasting your presence to nearby devices'),
            value: discovery.offGrid,
            onChanged: discovery.setOffGrid,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.block),
            title: const Text('Receive Off'),
            subtitle: const Text('Silently reject all new incoming chat requests'),
            value: discovery.receiveOff,
            onChanged: discovery.setReceiveOff,
          ),
          const Divider(),
          const ListTile(
            title: Text('Account', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            dense: true,
          ),
          _BiometricTile(auth: auth),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign Out & Erase Data', style: TextStyle(color: Colors.red)),
            onTap: () => _confirmSignOut(context, auth),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, AuthProvider auth) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('All data will be permanently erased from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
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
    if (mounted) setState(() { _available = available; _enabled = enabled; });
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    return SwitchListTile(
      title: const Text('Biometric Sign-In'),
      subtitle: const Text('Use fingerprint or face to sign in'),
      value: _enabled,
      onChanged: (v) async {
        if (v) {
          await widget.auth.enableBiometric();
          setState(() => _enabled = true);
        }
      },
    );
  }
}
