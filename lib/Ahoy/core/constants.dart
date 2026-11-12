class AhoyConstants {
  // BLE
  static const String bleServiceUuid = '12345678-1234-1234-1234-123456789abc';
  static const String bleCharacteristicUuid =
      '12345678-1234-1234-1234-123456789def';
  static const int bleChunkSize = 180; // bytes per BLE chunk (ATT MTU safe)
  static const int bleMaxPayloadBytes = 256 * 1024;
  static const int bleMaxActiveAssemblies = 16;

  // LAN
  static const int lanDiscoveryPort = 45678; // UDP broadcast
  static const int lanMessagingPort = 45679; // TCP
  static const int lanPeerExpirySeconds = 30;
  static const int lanBroadcastIntervalSeconds = 5;
  static const int lanMaxAnnouncementBytes = 64 * 1024;
  static const int lanMaxPayloadBytes = 16 * 1024 * 1024;
  static const int lanTcpIdleTimeoutSeconds = 10;
  static const int lanMaxMessagesPerConnection = 8;

  // Inbound hardening (audit M-8): bounded connections and a per-address
  // message rate limit so RSA work cannot be bought cheaply.
  static const int lanMaxConnections = 32;
  static const int lanMaxMessagesPerAddressPerWindow = 20;
  static const int lanRateWindowSeconds = 10;

  // Announcements carry a signed timestamp and are rejected outside this
  // window (sixth review, findings 1 and 2): a captured announcement can no
  // longer be replayed forever. Matches the chat freshness tolerance because
  // phones on a LAN may lack a shared clock source.
  static const int announcementFreshnessSeconds = 15 * 60;
  // Round-7 hardening: an absolute cap on one inbound LAN TCP connection's
  // lifetime regardless of activity, so a slow trickle cannot hold its
  // receive buffers open forever (the idle timeout alone is attacker
  // defeatable: every byte resets it).
  static const int lanTcpMaxLifetimeSeconds = 60;

  // Round-7 hardening: aggregate cap on bytes held in incomplete inbound LAN
  // TCP messages across all connections. Without it, lanMaxConnections ×
  // lanMaxPayloadBytes of unterminated buffers is allocatable at once.
  static const int lanMaxTotalBufferedBytes = 64 * 1024 * 1024;

  // Ninth review (N-2): the per-transport route and key maps are bounded
  // like the routing tables (spec §8), and UDP announcements are
  // rate-limited per address before RSA verification so a flood of unique
  // signed announcements cannot buy unbounded work or memory.
  static const int lanMaxRouteEntries = 512;
  static const int maxTransportKeyEntries = 512;
  static const int lanMaxAnnouncementsPerAddressPerWindow = 20;


  // WiFi Direct
  static const int wifiDirectMaxPayloadBytes = 10 * 1024 * 1024;

  // Storage keys SecureStore
  static const String keyUserId = 'ahoy_user_id';
  static const String keyPasswordHash = 'ahoy_password_hash';
  static const String keyPrivateKey = 'ahoy_private_key';
  static const String keyPublicKey = 'ahoy_public_key';
  static const String keyBiometricEnabled = 'ahoy_biometric_enabled';
  static const String keyLocalDataKey = 'ahoy_local_data_key';

  // Storage keys PrefsStore
  static const String prefProfile = 'ahoy_profile';
  static const String prefConversations = 'ahoy_conversations';
  static const String prefOffGrid = 'ahoy_off_grid';
  static const String prefReceiveOff = 'ahoy_receive_off';
  static const String prefBleEnabled = 'ahoy_ble_enabled';
  static const String prefLanEnabled = 'ahoy_lan_enabled';
  static const String prefWifiDirectEnabled = 'ahoy_wifi_direct_enabled';

  // Inbound hardening (audit M-2)
  static const int inboundMaxClockSkewSeconds = 15 * 60;
  static const int maxMsgIdLength = 64;

  // Media limits (audit M-5/L-11): one file and a total disk budget for the
  // ahoy_media_* collection.
  static const int maxMediaBytes = 5 * 1024 * 1024;
  static const int mediaQuotaBytes = 200 * 1024 * 1024;

  // Delivery retries (audit M-3)
  static const int maxSendRetries = 3;
  static const int maxOutboxPerPeer = 50;

  // Misc
  static const int shortIdLength = 6;
  static const int maxStatusLength = 80;
  static const int maxBioLength = 200;
  static const int peerStaleSeconds = 30;

  // Blocked peers
  static const String prefBlockedUuids = 'ahoy_blocked_uuids';

  // Written at sign-up; a password hash without this marker means the prefs
  // were wiped while the Keychain survived (iOS reinstall, audit M-1).
  static const String prefAccountMarker = 'ahoy_account_marker';

  // Round-8: identities are processed under a global budget so UUID
  // rotation cannot purchase unlimited RSA work (per-peer throttles are
  // rotation-defeatable).
  static const int maxIdentityProcessedPerWindow = 20;
  static const int identityBudgetWindowSeconds = 10;

  // Round-8: temporary transport identifiers (MAC addresses) live in their
  // own bounded routing table so ambient BLE devices cannot churn real
  // peers out of the verified-UUID table (spec §8).
  static const int maxTempPeerEntries = 128;

  // Set once the local data migrator has run; later launches skip it
  // instead of decrypting everything again (audit L-10).
  static const String prefLocalDataMigrated = 'ahoy_local_data_migrated';

  // Set when undecryptable local data was quarantined, consumed once by the
  // startup notice (audit M-1).
  static const String prefQuarantineNotice = 'ahoy_quarantine_notice';
}
