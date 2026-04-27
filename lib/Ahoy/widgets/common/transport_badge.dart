import 'package:flutter/material.dart';
import '../../core/enums.dart';

class TransportBadge extends StatelessWidget {
  final TransportMode mode;

  const TransportBadge({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
    if (mode == TransportMode.none) return const SizedBox.shrink();
    return Chip(
      avatar: Icon(_icon, size: 14, color: Colors.white),
      label: Text(_label, style: const TextStyle(fontSize: 11, color: Colors.white)),
      backgroundColor: _color,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  String get _label => switch (mode) {
        TransportMode.wifiDirect => 'WiFi Direct',
        TransportMode.lan => 'LAN',
        TransportMode.ble => 'BLE',
        TransportMode.none => '',
      };

  IconData get _icon => switch (mode) {
        TransportMode.wifiDirect => Icons.wifi,
        TransportMode.lan => Icons.router,
        TransportMode.ble => Icons.bluetooth,
        TransportMode.none => Icons.signal_wifi_off,
      };

  Color get _color => switch (mode) {
        TransportMode.wifiDirect => Colors.green.shade600,
        TransportMode.lan => Colors.blue.shade600,
        TransportMode.ble => Colors.indigo.shade400,
        TransportMode.none => Colors.grey,
      };
}
