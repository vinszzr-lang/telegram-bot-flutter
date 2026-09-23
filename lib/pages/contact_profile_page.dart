import 'package:flutter/material.dart';
import '../services/session.dart';
import '../widgets/verified_badge.dart';

class ContactProfilePage extends StatelessWidget {
  final Session session;
  final Map<String, dynamic> user;
  const ContactProfilePage({super.key, required this.session, required this.user});

  @override
  Widget build(BuildContext context) {
    final name = (user['name'] ?? user['displayName'] ?? user['username'] ?? 'Pengguna').toString();
    final username = (user['username'] ?? '').toString();
    final avatar = (user['avatarUrl'] ?? '').toString();
    final verified = user['verified'] == true;
    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      appBar: AppBar(backgroundColor: const Color(0xFF080D10), title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 40),
        children: [
          Center(child: Hero(tag: 'profile-$username', child: CircleAvatar(radius: 58, backgroundColor: const Color(0xFF17324A), backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null, child: avatar.isEmpty ? Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)) : null))),
          const SizedBox(height: 18),
          Center(child: Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: Text(name, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800))), if (verified) const Padding(padding: EdgeInsets.only(left: 6), child: VerifiedBadge(size: 19))])),
          const SizedBox(height: 4),
          Center(child: Text('@$username', style: const TextStyle(color: Colors.white54))),
          const SizedBox(height: 26),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: const Color(0xFF10171A), borderRadius: BorderRadius.circular(22), border: Border.all(color: Colors.white10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Tentang', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 10),
              Text((user['bio'] ?? '').toString().trim().isEmpty ? 'Belum menambahkan bio.' : user['bio'].toString(), style: const TextStyle(color: Colors.white70, height: 1.4)),
            ]),
          ),
        ],
      ),
    );
  }
}
