import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/discovery_provider.dart';

class DiscoveryControls extends StatelessWidget {
  const DiscoveryControls({super.key});

  @override
  Widget build(BuildContext context) {
    final discovery = context.watch<DiscoveryProvider>();

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Transports',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.wifi, size: 20),
            title: const Text('WiFi Direct'),
            subtitle: const Text('Fast P2P — best for media'),
            value: discovery.wifiDirectEnabled,
            onChanged: discovery.setWifiDirectEnabled,
          ),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.lan, size: 20),
            title: const Text('Local Network (LAN)'),
            subtitle: const Text('Works over shared WiFi'),
            value: discovery.lanEnabled,
            onChanged: discovery.setLanEnabled,
          ),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.bluetooth, size: 20),
            title: const Text('Bluetooth (BLE)'),
            subtitle: const Text('No WiFi needed — drains battery'),
            value: discovery.bleEnabled,
            onChanged: discovery.setBleEnabled,
          ),
          const Divider(height: 8),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.visibility_off, size: 20),
            title: const Text('Off the Grid'),
            subtitle: const Text('Stop broadcasting your presence'),
            value: discovery.offGrid,
            onChanged: discovery.setOffGrid,
          ),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.block, size: 20),
            title: const Text('Receive Off'),
            subtitle: const Text('Reject all new incoming chats'),
            value: discovery.receiveOff,
            onChanged: discovery.setReceiveOff,
          ),
        ],
      ),
    );
  }
}
