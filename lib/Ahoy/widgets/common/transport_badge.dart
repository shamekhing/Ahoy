import 'package:flutter/material.dart';
import '../../core/enums.dart';

/// A single badge for one transport mode.
class TransportBadge extends StatelessWidget {
  final TransportMode mode;

  const TransportBadge({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
    if (mode == TransportMode.none) return const SizedBox.shrink();
    return Chip(
      avatar: Icon(_icon, size: 14, color: Colors.white),
      label: Text(
        _label,
        style: const TextStyle(fontSize: 12, color: Colors.white),
      ),
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

/// Renders one [TransportBadge] per transport in [transports], ordered by
/// priority (WiFiDirect → LAN → BLE). Use this wherever a peer may be
/// reachable via multiple transports simultaneously.
class TransportBadges extends StatelessWidget {
  final Set<TransportMode> transports;

  const TransportBadges({super.key, required this.transports});

  @override
  Widget build(BuildContext context) {
    const order = [
      TransportMode.wifiDirect,
      TransportMode.lan,
      TransportMode.ble,
    ];
    final visible = order.where((m) => transports.contains(m)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      runSpacing: 2,
      children: visible.map((m) => TransportBadge(mode: m)).toList(),
    );
  }
}
