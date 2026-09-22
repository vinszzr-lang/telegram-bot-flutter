import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LocalCache {
  static Future<void> saveMessages(String username, List<Map<String, dynamic>> messages) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('chat_$username', jsonEncode(messages));
  }

  static Future<List<Map<String, dynamic>>> messages(String username) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('chat_$username');
    if (raw == null) return [];
    try {
      return List<Map<String, dynamic>>.from(
        jsonDecode(raw).map((e) => Map<String, dynamic>.from(e)),
      );
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearLocalMessages(String username) async {
    final p = await SharedPreferences.getInstance();
    await p.remove('chat_$username');
  }

  static String _readKey(String username) => 'chat_read_$username';

  static Future<void> markRead(String username, String isoTime) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_readKey(username), isoTime);
  }

  static Future<DateTime?> readAt(String username) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_readKey(username));
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static String _wallpaperKey(String username) => 'chat_wallpaper_$username';

  static Future<void> setWallpaper(String username, String path) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_wallpaperKey(username), path);
  }

  static Future<String?> wallpaper(String username) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_wallpaperKey(username));
  }
}
