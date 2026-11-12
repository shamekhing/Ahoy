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

  // Set when undecryptable local data was quarantined, consumed once by the
  // startup notice (audit M-1).
  static const String prefQuarantineNotice = 'ahoy_quarantine_notice';
}
