import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';

class PrefsStore {
  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  String? getString(String key) => _prefs.getString(key);

  Set<String> keys() => _prefs.getKeys();

  Future<void> setBool(String key, {required bool value}) async {
    await _prefs.setBool(key, value);
  }

  bool getBool(String key, {bool defaultValue = false}) =>
      _prefs.getBool(key) ?? defaultValue;

  Future<void> setJson(String key, Map<String, dynamic> value) async {
    await _prefs.setString(key, jsonEncode(value));
  }

  Map<String, dynamic>? getJson(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> setJsonList(String key, List<Map<String, dynamic>> value) async {
    await _prefs.setString(key, jsonEncode(value));
  }

  List<Map<String, dynamic>> getJsonList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  /// Moves an undecryptable value out of the live namespace so repeated
  /// reads cannot keep failing, keeping the original bytes for diagnostics
  /// (audit M-1). The first quarantined copy wins and sets the one-time
  /// startup notice flag.
  Future<void> quarantineValue(String key) async {
    final raw = _prefs.getString(key);
    if (raw == null) return;
    final quarantineKey = 'ahoy_corrupt_$key';
    if (_prefs.getString(quarantineKey) == null) {
      await _prefs.setString(quarantineKey, raw);
      await _prefs.setBool(AhoyConstants.prefQuarantineNotice, true);
    }
    await _prefs.remove(key);
  }

  Future<void> clearAll() async {
    await _prefs.clear();
  }
}
