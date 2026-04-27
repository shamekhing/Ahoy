class AhoyConstants {
  // BLE
  static const String bleServiceUuid = '12345678-1234-1234-1234-123456789abc';
  static const String bleCharacteristicUuid = '12345678-1234-1234-1234-123456789def';
  static const String bleProfileCharUuid = '12345678-1234-1234-1234-123456789aaa';
  static const int bleChunkSize = 180; // bytes per BLE chunk (ATT MTU safe)

  // LAN
  static const int lanDiscoveryPort = 45678; // UDP broadcast
  static const int lanMessagingPort = 45679; // TCP
  static const int lanPeerExpirySeconds = 30;
  static const int lanBroadcastIntervalSeconds = 5;

  // Storage keys — SecureStore
  static const String keyUserId = 'ahoy_user_id';
  static const String keyPasswordHash = 'ahoy_password_hash';
  static const String keyPrivateKey = 'ahoy_private_key';
  static const String keyPublicKey = 'ahoy_public_key';
  static const String keyBiometricEnabled = 'ahoy_biometric_enabled';

  // Storage keys — PrefsStore
  static const String prefProfile = 'ahoy_profile';
  static const String prefConversations = 'ahoy_conversations';
  static const String prefOffGrid = 'ahoy_off_grid';
  static const String prefReceiveOff = 'ahoy_receive_off';
  static const String prefBleEnabled = 'ahoy_ble_enabled';
  static const String prefLanEnabled = 'ahoy_lan_enabled';
  static const String prefWifiDirectEnabled = 'ahoy_wifi_direct_enabled';

  // Misc
  static const int shortIdLength = 6;
  static const int maxStatusLength = 80;
  static const int maxBioLength = 200;
}
