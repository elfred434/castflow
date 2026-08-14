import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

class SettingsRepository {
  static const _identityKey = 'castflow.identity';
  static const _downloadDirectoryKey = 'castflow.downloadDirectory';

  Future<DeviceInfo> loadIdentity() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_identityKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          final identity = DeviceInfo.fromJson(json.cast<String, Object?>());
          if (identity.id.isNotEmpty) return identity;
        }
      } on FormatException {
        // Régénérer une identité si la préférence a été corrompue.
      }
    }
    final identity = DeviceInfo.ephemeral();
    await preferences.setString(_identityKey, jsonEncode(identity.toJson()));
    return identity;
  }

  Future<String?> loadDownloadDirectory() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_downloadDirectoryKey);
  }

  Future<void> saveDownloadDirectory(String path) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_downloadDirectoryKey, path);
  }
}
