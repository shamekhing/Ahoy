import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../../core/constants.dart';
import '../../core/enums.dart';
import '../../core/logging.dart';
import '../crypto/crypto_service.dart';
import 'transport_interface.dart';

class LanTransport implements TransportInterface {
  @override
  TransportMode get mode => TransportMode.lan;

  final int _discoveryPort;
  final int _messagingPort;
  final int _maxPayloadBytes;
  final int _maxMessagesPerConnection;
  final Duration _tcpIdleTimeout;

  /// Absolute cap on one inbound TCP connection's lifetime regardless of
  /// activity (round 7): the idle timeout alone is attacker defeatable
  /// because every received byte resets it.
  final Duration _tcpMaxLifetime;
  final CryptoService? _crypto;

  final _packetController = StreamController<InboundPacket>.broadcast();
  final _announcementController =
      StreamController<PeerAnnouncement>.broadcast();

  @override
  Stream<InboundPacket> get packetStream => _packetController.stream;
  @override
  Stream<PeerAnnouncement> get announcementStream =>
      _announcementController.stream;

  RawDatagramSocket? _udpSocket;
  // Dedicated send socket so we don't hold up the receive socket between sends.
  RawDatagramSocket? _sendSocket;
  ServerSocket? _tcpServer;
  Timer? _broadcastTimer;
  bool _advertising = false;

  String? _myUuid;
  String? _myShortId;
  String? _myDisplayName;
  String? _myStatusMessage;
  String? _myPublicKeyPEM;

  // peerUuid → InternetAddress + port for TCP
  final Map<String, _PeerConn> _peerConns = {};

  /// /24 prefixes (e.g. "192.168.1") from which a valid UDP announcement was
  /// received TCP connections from other networks are rejected (audit M-4).
  final Set<String> _announceSubnets = {};

  /// Ahoy UUID → public key from its first verified announcement. A later
  /// announcement for the same UUID with a different key is refused before
  /// any route state changes (sixth review, finding 1).
  final Map<String, String> _uuidKeys = {};

  /// Bounded concurrent inbound connections and a per-address message rate
  /// limit so one peer cannot buy unlimited RSA work (audit M-8).
  int _activeConnections = 0;
  final Map<String, _RateWindow> _rateWindows = {};

  /// Fixed-window per-address rate limit for UDP announcements (ninth
  /// review N-2), checked before RSA verification so a flood of unique
  /// signed announcements stays off the crypto layer.
  final Map<String, _RateWindow> _announceWindows = {};
  final int _announceRate;

  /// Bounds for the per-transport route and key maps (ninth review N-2): a
  /// flood of unique valid announcements must not grow memory without bound
  /// (spec §8 bounds the manager's tables; these bound the transport's).
  final int _maxRouteEntries;
  final int _maxKnownKeys;

  /// Aggregate bytes currently buffered in incomplete inbound TCP messages
  /// across all connections (round 7). Bounded so lanMaxConnections ×
  /// lanMaxPayloadBytes of unterminated garbage cannot be resident at once.
  int _totalBufferedBytes = 0;
  late final int _maxTotalBufferedBytes;

  /// (uuid, signature) pairs of announcements already processed this session
  /// (round 7). A signature covers a fresh timestamp, so the same pair
  /// arriving again from any address is a replayed capture. Checked
  /// before RSA verification so replay floods never reach the crypto layer.
  final Set<String> _seenAnnouncements = {};
  static const int _maxSeenAnnouncements = 1024;

  @visibleForTesting
  int get debugActiveConnections => _activeConnections;

  @visibleForTesting
  Map<String, String> get debugUuidKeys => Map.unmodifiable(_uuidKeys);

  DateTime? _localSubnetsAt;
  Set<String> _localSubnetsCache = const {};

  LanTransport({
    int discoveryPort = AhoyConstants.lanDiscoveryPort,
    int messagingPort = AhoyConstants.lanMessagingPort,
    int maxPayloadBytes = AhoyConstants.lanMaxPayloadBytes,
    int maxMessagesPerConnection = AhoyConstants.lanMaxMessagesPerConnection,
    Duration tcpIdleTimeout = const Duration(
      seconds: AhoyConstants.lanTcpIdleTimeoutSeconds,
    ),
    Duration tcpMaxLifetime = const Duration(
      seconds: AhoyConstants.lanTcpMaxLifetimeSeconds,
    ),
    int? maxTotalBufferedBytes,
    int announceRatePerWindow =
        AhoyConstants.lanMaxAnnouncementsPerAddressPerWindow,
    int maxRouteEntries = AhoyConstants.lanMaxRouteEntries,
    int maxKnownKeys = AhoyConstants.maxTransportKeyEntries,
    CryptoService? crypto,
  }) : _discoveryPort = discoveryPort,
       _messagingPort = messagingPort,
       _maxPayloadBytes = maxPayloadBytes,
       _maxMessagesPerConnection = maxMessagesPerConnection,
       _tcpIdleTimeout = tcpIdleTimeout,
       _tcpMaxLifetime = tcpMaxLifetime,
       _maxTotalBufferedBytes =
           maxTotalBufferedBytes ?? AhoyConstants.lanMaxTotalBufferedBytes,
       _announceRate = announceRatePerWindow,
       _maxRouteEntries = maxRouteEntries,
       _maxKnownKeys = maxKnownKeys,
       _crypto = crypto;

  @visibleForTesting
  int? get debugMessagingPort => _tcpServer?.port;

  @override
  Future<void> startAdvertising({
    required String uuid,
    required String shortId,
    required String displayName,
    String? statusMessage,
    String? publicKeyPEM,
    String? announcementSignature,
  }) async {
    _myUuid = uuid;
    _myShortId = shortId;
    _myDisplayName = displayName;
    _myStatusMessage = statusMessage;
    _myPublicKeyPEM = publicKeyPEM;
    _advertising = true;
    _startBroadcastTimer();
  }

  @override
  Future<void> stopAdvertising() async {
    _advertising = false;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
  }

  @override
  Future<void> startScanning() async {
    await _refreshLocalSubnets();
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen(
        _onUdpDatagram,
        onError: (e) => ahoyLog('[LAN] UDP socket error', e),
      );
    } catch (e) {
      ahoyLog('[LAN] UDP bind failed', e);
    }

    // Shared send socket reused across all broadcast calls to avoid
    // creating a new socket per target per interval.
    try {
      _sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sendSocket!.broadcastEnabled = true;
    } catch (e) {
      ahoyLog('[LAN] UDP send socket bind failed', e);
    }

    try {
      _tcpServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        _messagingPort,
      );
      _tcpServer!.listen(_onTcpConnection);
    } catch (e) {
      ahoyLog('[LAN] TCP server bind failed', e);
    }
  }

  @override
  Future<void> stopScanning() async {
    _announceSubnets.clear();
    _announceWindows.clear();
    _udpSocket?.close();
    _udpSocket = null;
    _sendSocket?.close();
    _sendSocket = null;
    _tcpServer?.close();
    _tcpServer = null;
  }

  void _startBroadcastTimer() {
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: AhoyConstants.lanBroadcastIntervalSeconds),
      (_) => _broadcast(),
    );
    _broadcast();
  }

  Future<void> _broadcast() async {
    if (!_advertising || _myUuid == null) return;
    // Keep the interface cache fresh for the subnet filters (audit M-4).
    await _refreshLocalSubnets();

    // Re-sign each broadcast with a fresh timestamp: receivers reject
    // announcements older than the freshness window, so a fixed signature
    // would go stale mid-session (sixth review, findings 1 and 2).
    String? signature;
    var timestamp = '';
    final crypto = _crypto;
    if (crypto != null && crypto.isReady) {
      timestamp = DateTime.now().toIso8601String();
      try {
        signature = crypto.signAnnouncement(
          uuid: _myUuid!,
          shortId: _myShortId ?? '',
          displayName: _myDisplayName ?? '',
          statusMessage: _myStatusMessage,
          publicKeyPEM: _myPublicKeyPEM,
          timestamp: timestamp,
        );
      } catch (_) {
        return;
      }
    } else {
      return;
    }

    final data = utf8.encode(
      jsonEncode({
        'type': 'ahoy_announce',
        'uuid': _myUuid,
        'shortId': _myShortId,
        'displayName': _myDisplayName,
        'statusMessage': _myStatusMessage,
        'publicKeyPEM': _myPublicKeyPEM,
        'signature': signature,
        'timestamp': timestamp,
      }),
    );

    // Collect broadcast targets: limited broadcast + each interface's /24 subnet.
    final targets = <String>{'255.255.255.255'};
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (_) {}

    final sock = _sendSocket;
    if (sock == null) return;
    for (final target in targets) {
      try {
        sock.send(data, InternetAddress(target), _discoveryPort);
      } catch (e) {
        ahoyLog('[LAN] broadcast failed', e);
      }
    }
  }

  void _onUdpDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _udpSocket?.receive();
    if (dg == null) return;
    if (dg.data.length > AhoyConstants.lanMaxAnnouncementBytes) return;
    String raw;
    try {
      raw = utf8.decode(dg.data);
    } catch (_) {
      return;
    }
    _onAnnouncementJson(raw, dg.address);
  }

  /// Validates and applies one announcement datagram. Split from
  /// [_onUdpDatagram] so tests can feed announcements without sockets.
  void _onAnnouncementJson(String raw, InternetAddress senderAddress) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['type'] != 'ahoy_announce') return;
      final uuid = json['uuid'] as String?;
      if (uuid == null || uuid == _myUuid) return;

      // Only trust announcements that originate from our own interface
      // subnets (or loopback) cross-network spoofs are dropped and can
      // never poison the connect targets (audit M-4).
      if (!_isLocalOrLoopback(senderAddress)) {
        ahoyLog('[LAN] dropping announcement from foreign subnet');
        return;
      }

      // Per-address announcement rate limit (ninth review N-2): excess
      // datagrams are dropped before any parsing or verification work.
      // Loopback is exempt, matching the local-tooling carve-out on TCP.
      if (!_isLoopbackAddress(senderAddress) &&
          !_allowAnnouncement(senderAddress.address)) {
        ahoyLog('[LAN] dropping announcement over the rate limit');
        return;
      }

      // Verify the signed identity BEFORE any routing state is written —
      // LAN announces must carry a key and a valid signature over it
      // (audit #5). Fail closed when verification is unavailable.
      final crypto = _crypto;
      if (crypto == null) return;
      final pem = json['publicKeyPEM'] as String?;
      final signature = json['signature'] as String?;
      final displayName = json['displayName'] as String? ?? '';
      final shortId = json['shortId'] as String? ?? '';
      final statusMessage = json['statusMessage'] as String?;
      final timestamp = json['timestamp'] as String?;
      if (pem == null ||
          pem.isEmpty ||
          signature == null ||
          signature.isEmpty ||
          !CryptoService.isRealAhoyUuid(uuid) ||
          (shortId.isNotEmpty &&
              shortId.toUpperCase() != CryptoService.shortIdFromUuid(uuid)) ||
          // Freshness: a captured announcement replayed later must not
          // repoint routing or refresh a departed peer (sixth review,
          // findings 1 and 2).
          !CryptoService.isFreshTimestamp(timestamp)) {
        ahoyLog('[LAN] dropping announcement that fails verification');
        return;
      }

      // Same-key replay guard (round 7): the signature covers a fresh
      // timestamp, so an identical (uuid, signature) pair arriving again —
      // even from a different address is a replayed capture. Dropping it
      // before RSA verification keeps replay floods off the crypto layer.
      final announcementKey = '$uuid|$signature';
      if (_seenAnnouncements.contains(announcementKey)) {
        ahoyLog('[LAN] dropping replayed announcement');
        return;
      }

      // The first verified announcement for a UUID fixes its key. A later
      // announcement for the same UUID carrying a different key is refused
      // before any route state changes, so a second node holding a replayed
      // or differently-keyed announcement cannot steal the route (sixth
      // review, finding 1).
      final knownKey = _uuidKeys[uuid];
      if (knownKey != null && !_sameKey(knownKey, pem)) {
        ahoyLog('[LAN] dropping announcement with a conflicting key');
        return;
      }

      if (!crypto.verifyAnnouncement(
        uuid: uuid,
        shortId: shortId,
        displayName: displayName,
        statusMessage: statusMessage,
        publicKeyPEM: pem,
        signature: signature,
        timestamp: timestamp!,
      )) {
        ahoyLog('[LAN] dropping announcement with an invalid signature');
        return;
      }

      _seenAnnouncements.add(announcementKey);
      while (_seenAnnouncements.length > _maxSeenAnnouncements) {
        _seenAnnouncements.remove(_seenAnnouncements.first);
      }
      _uuidKeys[uuid] = pem;
      while (_uuidKeys.length > _maxKnownKeys) {
        _uuidKeys.remove(_uuidKeys.keys.first);
      }

      final prefix = _subnetPrefix(senderAddress.address);
      if (prefix != null) _announceSubnets.add(prefix);

      // Route pinning (round 7): a verified announcement only repoints the
      // TCP route when there is no route yet, when it comes from the already
      // pinned address, or when the pinned address has gone stale (peer
      // expiry). A captured announcement replayed from a neighbouring
      // address within the freshness window can therefore neither take over
      // the route of a live peer nor refresh presence from the wrong host.
      final now = DateTime.now();
      final existing = _peerConns[uuid];
      if (existing != null &&
          existing.address.address != senderAddress.address &&
          now.difference(existing.pinnedAt) <
              const Duration(seconds: AhoyConstants.lanPeerExpirySeconds)) {
        ahoyLog(
          '[LAN] keeping pinned route for $uuid; '
          'ignored announcement from ${senderAddress.address}',
        );
        return;
      }
      // The announced port is never trusted (audit M-5): the messaging port
      // is fixed on both ends of the protocol. The route table is bounded
      // (ninth review N-2): expired routes are dropped first, then the
      // oldest entries, so a flood of unique signed announcements cannot
      // grow memory without bound.
      _peerConns.removeWhere(
        (_, conn) =>
            now.difference(conn.pinnedAt) >=
            const Duration(seconds: AhoyConstants.lanPeerExpirySeconds),
      );
      _peerConns[uuid] = _PeerConn(senderAddress, _messagingPort, now);
      while (_peerConns.length > _maxRouteEntries) {
        _peerConns.remove(_peerConns.keys.first);
      }

      _announcementController.add(
        PeerAnnouncement(
          uuid: uuid,
          shortId: json['shortId'] as String? ?? '',
          displayName: json['displayName'] as String? ?? 'Unknown',
          statusMessage: json['statusMessage'] as String?,
          publicKeyPEM: pem,
          signature: signature,
          timestamp: timestamp,
          transport: TransportMode.lan,
        ),
      );
    } catch (_) {}
  }

  void _onTcpConnection(Socket socket) {
    if (_activeConnections >= AhoyConstants.lanMaxConnections) {
      ahoyLog('[LAN] connection cap reached; dropping incoming connection');
      socket.destroy();
      return;
    }
    if (!_isAllowedTcpPeer(socket.remoteAddress)) {
      ahoyLog('[LAN] rejecting TCP connection from unexpected network');
      socket.destroy();
      return;
    }
    _activeConnections++;
    final remoteAddress = socket.remoteAddress.address;
    final buffer = BytesBuilder();
    var bufferedBytes = 0;
    var messagesProcessed = 0;
    var closed = false;
    Timer? idleTimer;
    Timer? lifetimeTimer;

    void close({bool discardBuffer = false}) {
      if (closed) return;
      closed = true;
      idleTimer?.cancel();
      lifetimeTimer?.cancel();
      // Release this connection's share of the aggregate buffer budget
      // before clearing, so the global cap keeps tracking reality (round 7).
      _totalBufferedBytes -= bufferedBytes;
      if (_totalBufferedBytes < 0) _totalBufferedBytes = 0;
      bufferedBytes = 0;
      if (discardBuffer) buffer.clear();
      _activeConnections =
          _activeConnections > 0 ? _activeConnections - 1 : 0;
      socket.destroy();
    }

    /// Releases [count] bytes from the buffer accounting once they are no
    /// longer held as an incomplete message (round 7).
    void releaseBuffered(int count) {
      bufferedBytes -= count;
      _totalBufferedBytes -= count;
      if (_totalBufferedBytes < 0) _totalBufferedBytes = 0;
    }

    /// Fixed-window per-address rate limit: each processed message counts
    /// against the sender's address (audit M-8).
    bool allowMessage() {
      final now = DateTime.now();
      final window = _rateWindows[remoteAddress];
      if (window == null ||
          now.difference(window.start) >
              const Duration(seconds: AhoyConstants.lanRateWindowSeconds)) {
        _rateWindows[remoteAddress] = _RateWindow(now, 1);
        // Keep the window map bounded under address-spoofing floods.
        if (_rateWindows.length > 512) {
          _rateWindows.removeWhere(
            (_, w) => now.difference(w.start) >
                const Duration(seconds: AhoyConstants.lanRateWindowSeconds),
          );
        }
        return true;
      }
      window.count++;
      if (window.count > AhoyConstants.lanMaxMessagesPerAddressPerWindow) {
        ahoyLog('[LAN] message rate limit exceeded for $remoteAddress');
        close(discardBuffer: true);
        return false;
      }
      return true;
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(_tcpIdleTimeout, () => close(discardBuffer: true));
    }

    bool processMessage(List<int> raw) {
      if (messagesProcessed >= _maxMessagesPerConnection) {
        ahoyLog('[LAN] dropping TCP connection with too many messages');
        close(discardBuffer: true);
        return false;
      }

      var messageBytes = raw;
      if (messageBytes.isNotEmpty && messageBytes.last == 13) {
        messageBytes = messageBytes.sublist(0, messageBytes.length - 1);
      }
      if (messageBytes.isEmpty) return true;

      messagesProcessed += 1;
      _processMessageBytes(messageBytes);

      if (messagesProcessed >= _maxMessagesPerConnection) {
        close();
        return false;
      }
      return true;
    }

    resetIdleTimer();
    // Absolute lifetime cap (round 7): activity keeps the idle timer alive,
    // but no connection may hold its buffers beyond this bound.
    lifetimeTimer = Timer(_tcpMaxLifetime, () => close(discardBuffer: true));
    socket.listen(
      (chunk) {
        resetIdleTimer();
        buffer.add(chunk);
        bufferedBytes += chunk.length;
        _totalBufferedBytes += chunk.length;
        // Per-connection cap: one unterminated message may not exceed the
        // payload bound (as before, audit M-5).
        if (bufferedBytes > _maxPayloadBytes) {
          ahoyLog('[LAN] dropping oversized TCP payload');
          close(discardBuffer: true);
          return;
        }
        // Aggregate cap across all connections (round 7): memory stays
        // bounded no matter how many connections a flood opens.
        if (_totalBufferedBytes > _maxTotalBufferedBytes) {
          ahoyLog('[LAN] dropping connection over the aggregate buffer budget');
          close(discardBuffer: true);
          return;
        }

        // Split on newlines in bulk instead of walking the stream byte by
        // byte (round 7). Multiple messages arriving in one chunk are all
        // processed, with the original per-message accounting preserved.
        final data = buffer.takeBytes();
        var start = 0;
        while (!closed) {
          final newline = data.indexOf(10, start);
          if (newline < 0) break;
          final lineBytes = data.sublist(start, newline);
          final consumed = lineBytes.length + 1;
          start += consumed;
          releaseBuffered(consumed);
          if (!allowMessage()) return;
          if (!processMessage(lineBytes)) return;
        }
        if (!closed && start < data.length) {
          buffer.add(data.sublist(start));
        }
      },
      onDone: () {
        idleTimer?.cancel();
        lifetimeTimer?.cancel();
        // Process any bounded message that arrived without a trailing newline.
        if (!closed) {
          final rest = buffer.takeBytes();
          if (rest.isNotEmpty) {
            releaseBuffered(rest.length);
            processMessage(rest);
          }
        }
        // Release the connection slot on clean peer disconnects too (round
        // 7: the previous handler only decremented on error/timeout paths).
        if (!closed) close();
      },
      onError: (_) => close(discardBuffer: true),
    );
  }

  void _processMessageBytes(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maxPayloadBytes) return;
    try {
      _processMessage(utf8.decode(bytes));
    } catch (_) {}
  }

  void _processMessage(String raw) {
    if (raw.trim().isEmpty) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final from = json['from'] as String?;
      // Drop packets that claim to be from ourselves.
      if (from == null || from == _myUuid) return;
      _packetController.add(
        InboundPacket(
          peerUuid: from,
          peerShortId: json['fromShortId'] as String? ?? '',
          peerDisplayName: json['fromName'] as String? ?? 'Unknown',
          payload: raw,
          transport: TransportMode.lan,
        ),
      );
    } catch (_) {}
  }

  /// /24 prefixes of this host's non-loopback IPv4 interfaces. Refreshed
  /// on transport start and with each broadcast cycle; the sync path below
  /// only ever reads the cache.
  Future<void> _refreshLocalSubnets() async {
    final prefixes = <String>{};
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final prefix = _subnetPrefix(addr.address);
          if (prefix != null) prefixes.add(prefix);
        }
      }
    } catch (_) {}
    _localSubnetsCache = prefixes;
    _localSubnetsAt = DateTime.now();
  }

  Set<String> get _localSubnets {
    final now = DateTime.now();
    final cachedAt = _localSubnetsAt;
    if (cachedAt != null &&
        now.difference(cachedAt) < const Duration(seconds: 15)) {
      return _localSubnetsCache;
    }
    // Stale or missing refresh in the background and use what we have.
    unawaited(_refreshLocalSubnets());
    return _localSubnetsCache;
  }

  static String? _subnetPrefix(String ipv4) {
    final parts = ipv4.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  /// True for loopback addresses and addresses inside one of this host's own
  /// interface subnets the only legitimate origins of announcements.
  bool _isLocalOrLoopback(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      if (address.address.startsWith('127.')) return true;
      final prefix = _subnetPrefix(address.address);
      return prefix != null && _localSubnets.contains(prefix);
    }
    return address.isLoopback;
  }

  /// True only for loopback, which is exempt from the announcement rate
  /// limit so local tooling keeps working (ninth review N-2).
  bool _isLoopbackAddress(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      return address.address.startsWith('127.');
    }
    return address.isLoopback;
  }

  /// Fixed-window per-address rate limit for UDP announcements: each
  /// datagram that passes the subnet filter counts once, before any parsing
  /// or RSA verification (ninth review N-2). The window map is bounded the
  /// same way as the TCP message limiter.
  bool _allowAnnouncement(String address) {
    final now = DateTime.now();
    final window = _announceWindows[address];
    if (window == null ||
        now.difference(window.start) >
            const Duration(seconds: AhoyConstants.lanRateWindowSeconds)) {
      _announceWindows[address] = _RateWindow(now, 1);
      if (_announceWindows.length > 512) {
        _announceWindows.removeWhere(
          (_, w) => now.difference(w.start) >
              const Duration(seconds: AhoyConstants.lanRateWindowSeconds),
        );
      }
      return true;
    }
    window.count++;
    return window.count <= _announceRate;
  }

  /// TCP peers must come from a subnet that actually announced itself
  /// (audit M-4) or from loopback, which keeps local tooling working.
  bool _isAllowedTcpPeer(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4 &&
        address.address.startsWith('127.')) {
      return true;
    }
    final prefix = _subnetPrefix(address.address);
    return prefix != null && _announceSubnets.contains(prefix);
  }

  @visibleForTesting
  int? get debugDiscoveryPort => _udpSocket?.port;

  @visibleForTesting
  int get debugPeerConnCount => _peerConns.length;

  @visibleForTesting
  void debugAllowSubnet(String prefix) => _announceSubnets.add(prefix);

  @visibleForTesting
  bool debugIsAllowedTcpPeer(String ipv4) =>
      _isAllowedTcpPeer(InternetAddress(ipv4));

  @visibleForTesting
  bool debugIsLocalOrLoopback(String ipv4) =>
      _isLocalOrLoopback(InternetAddress(ipv4));

  @visibleForTesting
  InternetAddress? debugRouteAddress(String uuid) => _peerConns[uuid]?.address;

  @visibleForTesting
  DateTime? debugRoutePinnedAt(String uuid) => _peerConns[uuid]?.pinnedAt;

  /// Marks every pinned route stale so takeover tests do not have to wait
  /// out the peer expiry window (round 7).
  @visibleForTesting
  void debugExpireRoutes() {
    final stale = DateTime.now().subtract(
      const Duration(seconds: AhoyConstants.lanPeerExpirySeconds + 1),
    );
    _peerConns.updateAll(
      (_, conn) => _PeerConn(conn.address, conn.port, stale),
    );
  }

  @visibleForTesting
  int get debugSeenAnnouncementCount => _seenAnnouncements.length;

  /// Feeds a datagram address through the announcement rate limiter without
  /// touching a socket (ninth review tests).
  @visibleForTesting
  bool debugAllowAnnouncement(String address) => _allowAnnouncement(address);

  /// Feeds a raw announcement through the full validation pipeline without
  /// touching a socket (round 7 tests).
  @visibleForTesting
  void debugHandleAnnouncement(String rawJson, InternetAddress from) =>
      _onAnnouncementJson(rawJson, from);

  @override
  Future<bool> send(String peerUuid, String payload) async {
    final payloadBytes = utf8.encode(payload);
    if (payloadBytes.length > _maxPayloadBytes) {
      ahoyLog('[LAN] refusing oversized payload');
      return false;
    }

    final conn = _peerConns[peerUuid];
    if (conn == null) return false;
    Socket? socket;
    try {
      socket = await Socket.connect(
        conn.address,
        conn.port,
        timeout: const Duration(seconds: 5),
      );
      socket.add(payloadBytes);
      socket.add(const [10]);
      await socket.flush();
      return true;
    } catch (e) {
      ahoyLog('[LAN] send failed', e);
      // Remove stale entry the next UDP announcement will re-add it.
      _peerConns.remove(peerUuid);
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {
    await stopAdvertising();
    await stopScanning();
    _peerConns.clear();
    _packetController.close();
    _announcementController.close();
  }
}

class _PeerConn {
  final InternetAddress address;
  final int port;

  /// Last time a verified announcement refreshed the route from [address]
  /// (round 7). Route takeover from a different address requires this to be
  /// older than the peer expiry window, so a replayed announcement cannot
  /// repoint the route of a live peer.
  final DateTime pinnedAt;

  _PeerConn(this.address, this.port, [DateTime? pinnedAt])
    : pinnedAt = pinnedAt ?? DateTime.now();
}

/// Whitespace-insensitive PEM comparison, matching the other layers.
bool _sameKey(String a, String b) {
  final ws = RegExp(r'\s+');
  return a.replaceAll(ws, '') == b.replaceAll(ws, '');
}

/// Fixed-window rate limiter state per remote address (audit M-8).
class _RateWindow {
  final DateTime start;
  int count;

  _RateWindow(this.start, this.count);
}
