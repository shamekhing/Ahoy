import 'package:flutter/foundation.dart';
import '../core/enums.dart';
import '../services/transport_manager.dart';

class TransportProvider extends ChangeNotifier {
  final TransportManager _manager;

  TransportProvider(this._manager);

  /// Returns the best live transport for a peer — computed fresh every call.
  TransportMode modeFor(String peerUuid) => _manager.currentModeFor(peerUuid);

  bool get isBleOnly => false; // Checked per-peer via modeFor()

  bool canSendMedia(String peerUuid) {
    final mode = modeFor(peerUuid);
    return mode == TransportMode.lan || mode == TransportMode.wifiDirect;
  }
}
