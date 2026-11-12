import 'dart:io';

import 'package:ahoy/Ahoy/core/constants.dart';
import 'package:ahoy/Ahoy/services/crypto/crypto_service.dart';
import 'package:ahoy/Ahoy/services/crypto/peer_trust_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Appendix E gate item 5: Appendix A of PROTOCOL.md must match the
/// constants in the code. This test reads both the document and the source.
void main() {
  late String doc;
  late String chatSource;
  late String lanSource;
  late String bleSource;
  late String wdSource;
  late String kotlinSource;

  setUpAll(() async {
    doc = await File('PROTOCOL.md').readAsString();
    chatSource = await File(
      'lib/Ahoy/services/chat/chat_service.dart',
    ).readAsString();
    lanSource = await File(
      'lib/Ahoy/services/transport/lan_transport.dart',
    ).readAsString();
    bleSource = await File(
      'lib/Ahoy/services/transport/ble_transport.dart',
    ).readAsString();
    wdSource = await File(
      'lib/Ahoy/services/transport/wifi_direct_transport.dart',
    ).readAsString();
    kotlinSource = await File(
      'android/app/src/main/kotlin/com/ahoy/app/MainActivity.kt',
    ).readAsString();
  });

  void expectRow(String label, String value) {
    expect(
      doc,
      contains('| $label | $value |'),
      reason: 'Appendix A row: $label',
    );
  }

  test('Appendix A rows match the code constants', () {
    expectRow(
      'Timestamp freshness window (announce, chat, identity, ack)',
      '±15 min',
    );
    expect(
      AhoyConstants.announcementFreshnessSeconds,
      AhoyConstants.inboundMaxClockSkewSeconds,
    );
    expect(AhoyConstants.inboundMaxClockSkewSeconds, 15 * 60);

    expectRow('Announcement broadcast interval (LAN)', '5 s');
    expect(AhoyConstants.lanBroadcastIntervalSeconds, 5);

    expectRow('Announcement stale expiry', '30 s');
    expect(AhoyConstants.lanPeerExpirySeconds, 30);

    expectRow('Announcement max size (LAN UDP)', '64 KiB');
    expect(AhoyConstants.lanMaxAnnouncementBytes, 64 * 1024);

    expectRow('Public key max PEM length', '4096 bytes');
    expect(CryptoService.maxPemLength, 4096);

    expectRow('Seen message-ID set size', '512');
    expect(chatSource, contains('int _maxSeenMessageIds = 512;'));

    expectRow('Trust record cap', '256');
    expect(PeerTrustStore.maxEntries, 256);

    expectRow('Identity throttle, per peer, inbound', '2 s');
    expect(chatSource, contains('const Duration(seconds: 2)'));

    expectRow('Identity peer map size (throttles, replied set)', '256');
    expect(chatSource, contains('static const int _maxIdentityPeers = 256;'));

    expectRow('LAN UDP port', '45678');
    expect(AhoyConstants.lanDiscoveryPort, 45678);

    expectRow('LAN TCP port', '45679');
    expect(AhoyConstants.lanMessagingPort, 45679);

    expectRow('LAN max payload', '16 MiB');
    expect(AhoyConstants.lanMaxPayloadBytes, 16 * 1024 * 1024);

    expectRow('LAN messages per TCP connection', '8');
    expect(AhoyConstants.lanMaxMessagesPerConnection, 8);

    expectRow('LAN messages per remote address per window', '20 per 10 s');
    expect(AhoyConstants.lanMaxMessagesPerAddressPerWindow, 20);
    expect(AhoyConstants.lanRateWindowSeconds, 10);

    expectRow('LAN TCP idle timeout', '10 s');
    expect(AhoyConstants.lanTcpIdleTimeoutSeconds, 10);

    expectRow('LAN absolute TCP connection lifetime', '60 s');
    expect(AhoyConstants.lanTcpMaxLifetimeSeconds, 60);

    expectRow('LAN aggregate inbound buffer budget', '64 MiB');
    expect(AhoyConstants.lanMaxTotalBufferedBytes, 64 * 1024 * 1024);

    expectRow('LAN outbound connect timeout', '5 s');
    expect(lanSource, contains('timeout: const Duration(seconds: 5)'));

    expectRow('WiFi Direct TCP port', '8765');
    expect(kotlinSource, contains('P2P_PORT = 8765'));

    expectRow('WiFi Direct max payload', '10 MiB');
    expect(AhoyConstants.wifiDirectMaxPayloadBytes, 10 * 1024 * 1024);

    expectRow('WiFi Direct socket read timeout', '10 s');
    expect(kotlinSource, contains('soTimeout = 10_000'));

    expectRow('WiFi Direct connect attempt TTL', '30 s');
    expect(wdSource, contains('Duration(seconds: 30)'));

    expectRow(
      'WiFi Direct auto-connect strikes before giving up on a device',
      '2',
    );
    expect(
      wdSource,
      contains('static const int _maxAutoConnectAttempts = 2;'),
    );

    expectRow('BLE chunk size', '180 bytes');
    expect(AhoyConstants.bleChunkSize, 180);

    expectRow('BLE max payload', '256 KiB');
    expect(AhoyConstants.bleMaxPayloadBytes, 256 * 1024);

    expectRow('BLE max concurrent reassembly buffers', '16');
    expect(AhoyConstants.bleMaxActiveAssemblies, 16);

    expectRow('BLE reassembly eviction', '60 s');
    expect(bleSource, contains('const Duration(seconds: 60)'));

    expectRow('BLE idle GATT disconnect', '5 min');
    expect(
      bleSource,
      contains(
        'static const Duration _idleConnectionThreshold = Duration(minutes: 5)',
      ),
    );

    expectRow('Message ID max length', '64');
    expect(AhoyConstants.maxMsgIdLength, 64);

    expectRow('Preview length (reply)', '80 characters');
    expect(AhoyConstants.maxStatusLength, 80);

    expectRow('Media file max', '5 MiB');
    expect(AhoyConstants.maxMediaBytes, 5 * 1024 * 1024);

    expectRow('Media storage quota', '200 MiB');
    expect(AhoyConstants.mediaQuotaBytes, 200 * 1024 * 1024);

    expectRow('Send retries before `failed` is final', '3');
    expect(AhoyConstants.maxSendRetries, 3);

    expectRow('Outbox entries per peer', '50');
    expect(AhoyConstants.maxOutboxPerPeer, 50);

    expectRow('Max bio length', '200 characters');
    expect(AhoyConstants.maxBioLength, 200);

    expectRow('Password minimum length', '8 characters');
    final authSource = File('lib/Ahoy/services/auth/auth_service.dart');
    expect(
      authSource.existsSync() &&
          authSource.readAsStringSync().contains('password.length < 8'),
      isTrue,
    );

    expectRow('PBKDF2 iterations (current)', '310,000');
    expect(CryptoService.passwordHashIterations, 310000);
  });
}
