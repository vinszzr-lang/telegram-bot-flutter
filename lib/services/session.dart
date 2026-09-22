import 'package:shared_preferences/shared_preferences.dart';

class Session {
  String? token;
  String? username;
  String? firstName;
  String? lastName;
  bool verified = false;
  String? avatarUrl;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    token = p.getString('token');
    username = p.getString('username');
    firstName = p.getString('firstName');
    lastName = p.getString('lastName');
    verified = p.getBool('verified') ?? false;
    // Avatar is read by the profile/home/chat UI through this property.
    avatarUrl = p.getString('avatarUrl');
  }

  Future<void> save(Map<String, dynamic> data) async {
    final p = await SharedPreferences.getInstance();
    token = data['token']?.toString();
    final user = Map<String, dynamic>.from(data['user'] ?? data);
    username = user['username']?.toString();
    firstName = user['firstName']?.toString();
    lastName = user['lastName']?.toString();
    verified = user['verified'] == true;
    avatarUrl = user['avatarUrl']?.toString();
    if (token != null) await p.setString('token', token!);
    if (username != null) await p.setString('username', username!);
    await p.setString('firstName', firstName ?? '');
    await p.setString('lastName', lastName ?? '');
    await p.setBool('verified', verified);
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      await p.setString('avatarUrl', avatarUrl!);
    } else {
      await p.remove('avatarUrl');
    }
  }

  Future<void> updateUser(Map<String, dynamic> user) async {
    final nextUsername = user['username']?.toString();
    final nextFirst = user['firstName']?.toString();
    final nextLast = user['lastName']?.toString();
    final nextVerified = user['verified'] == true;
    final nextAvatar = user['avatarUrl']?.toString();
    final changed = username != nextUsername || firstName != nextFirst || lastName != nextLast || verified != nextVerified || avatarUrl != nextAvatar;
    username = nextUsername;
    firstName = nextFirst;
    lastName = nextLast;
    verified = nextVerified;
    avatarUrl = nextAvatar;
    if (!changed) return;
    final p = await SharedPreferences.getInstance();
    if (username != null) await p.setString('username', username!);
    await p.setString('firstName', firstName ?? '');
    await p.setString('lastName', lastName ?? '');
    await p.setBool('verified', verified);
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      await p.setString('avatarUrl', avatarUrl!);
    } else {
      await p.remove('avatarUrl');
    }
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.clear();
    token = username = firstName = lastName = null;
    avatarUrl = null;
    verified = false;
  }

  String get displayName => '${firstName ?? ''} ${lastName ?? ''}'.trim();
}
