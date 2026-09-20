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
    try { return List<Map<String, dynamic>>.from(jsonDecode(raw).map((e) => Map<String, dynamic>.from(e))); } catch (_) { return []; }
  }
}
