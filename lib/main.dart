import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'https://addcybagfkoqietbpshd.supabase.co';
const supabasePublishableKey = 'sb_publishable_w2YDgscoFdW-JjQcXq_Cvw_iSCLD-9N';
const red = Color(0xFFFF3B55);
const bg = Color(0xFFF7F8FC);
final supabase = Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Chat',
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: red, brightness: Brightness.light)),
    home: const AuthGate(),
  );
}

class AuthGate extends StatefulWidget { const AuthGate({super.key}); @override State<AuthGate> createState() => _AuthGateState(); }
class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> _sub;
  @override void initState() { super.initState(); _sub = supabase.auth.onAuthStateChange.listen((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { _sub.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final user = supabase.auth.currentUser;
    if (user == null) return const LoginPage();
    return FutureBuilder<Map<String, dynamic>?>(future: profileOf(user.id), builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) return const Splash();
      final p = snap.data;
      if (p == null || (p['username'] ?? '').toString().trim().isEmpty) return const UsernamePage();
      return HomePage(profile: p);
    });
  }
}

Future<Map<String, dynamic>?> profileOf(String id) async {
  try { return await supabase.from('profiles').select().eq('id', id).maybeSingle(); } catch (_) { return null; }
}

class Splash extends StatelessWidget { const Splash({super.key}); @override Widget build(BuildContext c) => const Scaffold(body: Center(child: CircularProgressIndicator())); }

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});
  Future<void> login() => supabase.auth.signInWithOAuth(OAuthProvider.google, redirectTo: 'com.nullx.evo://login-callback');
  @override Widget build(BuildContext context) => Scaffold(body: Center(child: Padding(
    padding: const EdgeInsets.all(28), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 92, height: 92, decoration: BoxDecoration(color: red, borderRadius: BorderRadius.circular(28)), child: const Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 50)),
      const SizedBox(height: 24), const Text('Chat', style: TextStyle(fontSize: 38, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8), const Text('Ngobrol cepat, simpel, dan realtime.', textAlign: TextAlign.center, style: TextStyle(color: Colors.black54, fontSize: 16)),
      const SizedBox(height: 32), SizedBox(width: double.infinity, height: 54, child: FilledButton.icon(onPressed: login, icon: const Icon(Icons.g_mobiledata_rounded, size: 30), label: const Text('Lanjut dengan Google', style: TextStyle(fontWeight: FontWeight.w700)))),
    ]),
  )));
}

class UsernamePage extends StatefulWidget { const UsernamePage({super.key}); @override State<UsernamePage> createState() => _UsernamePageState(); }
class _UsernamePageState extends State<UsernamePage> {
  final ctl = TextEditingController(); bool busy = false; String? error;
  Future<void> save() async {
    final username = ctl.text.trim().toLowerCase().replaceAll(' ', '');
    if (username.length < 3 || !RegExp(r'^[a-z0-9_.]+$').hasMatch(username)) { setState(() => error = 'Username 3+ karakter: huruf, angka, titik, underscore.'); return; }
    setState(() { busy = true; error = null; });
    try {
      final exists = await supabase.from('profiles').select('id').eq('username', username).maybeSingle();
      if (exists != null) { setState(() { busy = false; error = 'Username sudah dipakai.'; }); return; }
      final u = supabase.auth.currentUser!;
      final meta = u.userMetadata ?? {};
      await supabase.from('profiles').upsert({'id': u.id, 'username': username, 'display_name': meta['full_name'] ?? username, 'avatar_url': meta['avatar_url']});
      if (mounted) setState(() => busy = false);
    } catch (_) { if (mounted) setState(() { busy = false; error = 'Gagal menyimpan username.'; }); }
  }
  @override Widget build(BuildContext context) => Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    const Text('Pilih username', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)), const SizedBox(height: 8),
    const Text('Orang lain menemukan kamu lewat username ini.', textAlign: TextAlign.center), const SizedBox(height: 24),
    TextField(controller: ctl, autofocus: true, decoration: InputDecoration(labelText: 'Username', prefixText: '@', errorText: error, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)))),
    const SizedBox(height: 18), SizedBox(width: double.infinity, height: 52, child: FilledButton(onPressed: busy ? null : save, child: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Simpan'))),
  ]))));
}

class HomePage extends StatefulWidget { final Map<String, dynamic> profile; const HomePage({super.key, required this.profile}); @override State<HomePage> createState() => _HomePageState(); }
class _HomePageState extends State<HomePage> {
  int tab = 0; final search = TextEditingController(); List<Map<String, dynamic>> chats = []; bool loading = true;
  @override void initState() { super.initState(); load(); }
  Future<void> load() async {
    try {
      final me = supabase.auth.currentUser!.id;
      final members = await supabase.from('conversation_members').select('conversation_id').eq('user_id', me);
      final ids = (members as List).map((e) => e['conversation_id']).toList();
      if (ids.isEmpty) { if (mounted) setState(() { chats = []; loading = false; }); return; }
      final rows = await supabase.from('conversations').select().inFilter('id', ids).order('updated_at', ascending: false);
      final result = <Map<String, dynamic>>[];
      for (final row in rows as List) {
        final ms = await supabase.from('conversation_members').select('user_id').eq('conversation_id', row['id']);
        final other = (ms as List).map((e) => e['user_id']).firstWhere((x) => x != me, orElse: () => null);
        Map<String, dynamic>? p;
        if (other != null) p = await profileOf(other.toString());
        result.add({...Map<String, dynamic>.from(row), 'other_profile': p});
      }
      if (mounted) setState(() { chats = result; loading = false; });
    } catch (_) { if (mounted) setState(() => loading = false); }
  }
  Future<void> searchUsers() async {
    final q = search.text.trim().replaceFirst('@', '').toLowerCase(); if (q.isEmpty) return;
    final rows = await supabase.from('profiles').select().ilike('username', '%$q%').limit(20);
    if (!mounted) return;
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.white, builder: (_) => SafeArea(child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(20), children: [
      const Text('Cari pengguna', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(height: 12),
      ...(rows as List).map((x) { final p = Map<String, dynamic>.from(x); return ListTile(leading: Avatar(url: p['avatar_url'], name: p['display_name'] ?? p['username']), title: Text(p['display_name'] ?? p['username']), subtitle: Text('@${p['username']}'), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => ProfilePage(profile: p))); }); }),
    ])));
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: bg, elevation: 0, title: const Text('Pesan', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
    actions: [IconButton(onPressed: () { showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Cari username'), content: TextField(controller: search, autofocus: true, decoration: const InputDecoration(prefixText: '@')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')), FilledButton(onPressed: () { Navigator.pop(context); searchUsers(); }, child: const Text('Cari'))])); }, icon: const Icon(Icons.search_rounded)), IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(profile: widget.profile))), icon: const Icon(Icons.settings_outlined))],
    body: tab == 0 ? RefreshIndicator(onRefresh: load, child: loading ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.only(top: 8), children: [if (chats.isEmpty) const EmptyChats(), ...chats.map((x) => ChatTile(data: x))])) : ProfilePage(profile: widget.profile),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Chat'), NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profil')]),
    floatingActionButton: tab == 0 ? FloatingActionButton(backgroundColor: red, foregroundColor: Colors.white, onPressed: () { showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Cari username'), content: TextField(controller: search, autofocus: true, decoration: const InputDecoration(prefixText: '@')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')), FilledButton(onPressed: () { Navigator.pop(context); searchUsers(); }, child: const Text('Cari'))])); }, child: const Icon(Icons.edit_rounded)) : null,
  );
}

class EmptyChats extends StatelessWidget { const EmptyChats({super.key}); @override Widget build(BuildContext c) => Padding(padding: const EdgeInsets.all(50), child: Column(children: [Icon(Icons.forum_outlined, size: 70, color: red.withValues(alpha: .7)), const SizedBox(height: 15), const Text('Belum ada chat', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)), const SizedBox(height: 5), const Text('Cari username untuk memulai percakapan.', textAlign: TextAlign.center)])); }
class ChatTile extends StatelessWidget { final Map<String, dynamic> data; const ChatTile({super.key, required this.data}); @override Widget build(BuildContext c) { final p = data['other_profile'] as Map<String, dynamic>?; return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5), leading: Avatar(url: p?['avatar_url'], name: p?['display_name'] ?? p?['username']), title: Text(p?['display_name'] ?? p?['username'] ?? 'Chat', style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('@${p?['username'] ?? ''}'), onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatPage(conversation: data))).then((_) => (c as Element).markNeedsBuild()); } }

class ProfilePage extends StatelessWidget { final Map<String, dynamic> profile; const ProfilePage({super.key, required this.profile}); @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Profil')), body: ListView(padding: const EdgeInsets.all(25), children: [Center(child: Avatar(url: profile['avatar_url'], name: profile['display_name'] ?? profile['username'], size: 110)), const SizedBox(height: 18), Center(child: Text(profile['display_name'] ?? profile['username'] ?? '', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800))), Center(child: Text('@${profile['username'] ?? ''}', style: const TextStyle(color: Colors.black54))), if ((profile['bio'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 18), child: Text(profile['bio'].toString(), textAlign: TextAlign.center)), const SizedBox(height: 28), if (profile['id'] != supabase.auth.currentUser?.id) FilledButton.icon(onPressed: () => _openChat(c, profile), icon: const Icon(Icons.chat_bubble_outline), label: const Text('Mulai chat'))])); }
Future<void> _openChat(BuildContext context, Map<String, dynamic> p) async {
  final me = supabase.auth.currentUser!.id;
  try {
    final existing = await supabase.from('conversation_members').select('conversation_id').eq('user_id', me);
    for (final row in existing as List) {
      final id = row['conversation_id']; final other = await supabase.from('conversation_members').select('user_id').eq('conversation_id', id).eq('user_id', p['id']).maybeSingle();
      if (other != null) { Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversation: {'id': id, 'other_profile': p}))); return; }
    }
    final conv = await supabase.from('conversations').insert({'type': 'direct'}).select().single();
    await supabase.from('conversation_members').insert([{'conversation_id': conv['id'], 'user_id': me}, {'conversation_id': conv['id'], 'user_id': p['id']}]);
    if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversation: {'id': conv['id'], 'other_profile': p})));
  } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tidak bisa membuat chat.'))); }
}

class ChatPage extends StatefulWidget { final Map<String, dynamic> conversation; const ChatPage({super.key, required this.conversation}); @override State<ChatPage> createState() => _ChatPageState(); }
class _ChatPageState extends State<ChatPage> {
  final ctl = TextEditingController(); final scroll = ScrollController(); List<Map<String, dynamic>> messages = []; Map<String, dynamic>? reply; bool typing = false; Timer? typingTimer; RealtimeChannel? channel;
  @override void initState() { super.initState(); load(); channel = supabase.channel('chat:${widget.conversation['id']}').onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'messages', filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'conversation_id', value: widget.conversation['id']), callback: (_) => load()).subscribe(); }
  @override void dispose() { typingTimer?.cancel(); if (channel != null) supabase.removeChannel(channel!); ctl.dispose(); scroll.dispose(); super.dispose(); }
  Future<void> load() async { final rows = await supabase.from('messages').select().eq('conversation_id', widget.conversation['id']).order('created_at'); if (mounted) setState(() => messages = (rows as List).map((x) => Map<String, dynamic>.from(x)).toList()); }
  void composerChanged(String value) { typingTimer?.cancel(); setState(() => typing = value.trim().isNotEmpty); typingTimer = Timer(const Duration(seconds: 2), () { if (mounted) setState(() => typing = false); }); }
  Future<void> send({String? content, String type = 'text', String? attachment}) async { final text = content ?? ctl.text.trim(); if (text.isEmpty && attachment == null) return; await supabase.from('messages').insert({'conversation_id': widget.conversation['id'], 'sender_id': supabase.auth.currentUser!.id, 'content': text, 'type': type, 'reply_to_id': reply?['id'], 'attachment_url': attachment}); ctl.clear(); setState(() { reply = null; typing = false; }); await load(); }
  Future<void> pickImage() async { final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85); if (x == null) return; try { final path = '${supabase.auth.currentUser!.id}/${DateTime.now().millisecondsSinceEpoch}_${x.name}'; await supabase.storage.from('media').upload(path, File(x.path), fileOptions: const FileOptions(upsert: true)); final url = supabase.storage.from('media').getPublicUrl(path); await send(type: 'image', attachment: url); } catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload gambar gagal.'))); } }
  Future<void> deleteMessage(Map<String, dynamic> msg, bool everyone) async { if (everyone) { await supabase.from('messages').update({'is_deleted': true, 'content': 'Pesan dihapus'}).eq('id', msg['id']).eq('sender_id', supabase.auth.currentUser!.id); } await load(); }
  @override Widget build(BuildContext context) { final p = widget.conversation['other_profile'] as Map<String, dynamic>?; return Scaffold(appBar: AppBar(title: Row(children: [Avatar(url: p?['avatar_url'], name: p?['display_name'] ?? p?['username'], size: 38), const SizedBox(width: 10), Expanded(child: Text(p?['display_name'] ?? p?['username'] ?? 'Chat', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)))])), body: Column(children: [Expanded(child: ListView.builder(controller: scroll, padding: const EdgeInsets.all(14), itemCount: messages.length + (typing ? 1 : 0), itemBuilder: (c, i) { if (i == messages.length) return const TypingBubble(); final msg = messages[i]; return MessageBubble(msg: msg, onReply: () => setState(() => reply = msg), onDelete: deleteMessage, onJump: (id) { final index = messages.indexWhere((m) => m['id'] == id); if (index >= 0) scroll.animateTo(index * 72.0, duration: const Duration(milliseconds: 180), curve: Curves.easeOut); }); })), if (reply != null) Container(color: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: Row(children: [Container(width: 3, height: 38, color: reply!['sender_id'] == supabase.auth.currentUser?.id ? Colors.green : red), const SizedBox(width: 8), Expanded(child: Text('Membalas: ${reply!['content'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis)), IconButton(onPressed: () => setState(() => reply = null), icon: const Icon(Icons.close))])), SafeArea(child: Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(8, 6, 8, 6), child: Row(children: [IconButton(onPressed: pickImage, icon: const Icon(Icons.photo_outlined)), Expanded(child: TextField(controller: ctl, onChanged: composerChanged, maxLines: 5, minLines: 1, decoration: InputDecoration(hintText: 'Tulis pesan...', filled: true, fillColor: bg, border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11)))), const SizedBox(width: 5), CircleAvatar(backgroundColor: red, child: IconButton(onPressed: send, color: Colors.white, icon: const Icon(Icons.send_rounded))) ]))) ])); }
}

class TypingBubble extends StatelessWidget { const TypingBubble({super.key}); @override Widget build(BuildContext c) => Align(alignment: Alignment.centerLeft, child: Container(margin: const EdgeInsets.all(6), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)), child: const Text('Mengetik...', style: TextStyle(color: Colors.black54)))); }
class MessageBubble extends StatelessWidget { final Map<String, dynamic> msg; final VoidCallback onReply; final Future<void> Function(Map<String, dynamic>, bool) onDelete; final ValueChanged<dynamic> onJump; const MessageBubble({super.key, required this.msg, required this.onReply, required this.onDelete, required this.onJump});
  @override Widget build(BuildContext context) { final own = msg['sender_id'] == supabase.auth.currentUser?.id; final deleted = msg['is_deleted'] == true; final content = (msg['content'] ?? '').toString(); return GestureDetector(onHorizontalDragEnd: (d) { if ((d.primaryVelocity ?? 0) > 500) { HapticFeedback.mediumImpact(); onReply(); } }, onLongPress: () => showModalBottomSheet(context: context, showDragHandle: true, builder: (_) => SafeArea(child: Wrap(children: [ListTile(leading: const Icon(Icons.reply), title: const Text('Balas'), onTap: () { Navigator.pop(context); onReply(); }), ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: const Text('Hapus untuk saya'), onTap: () { Navigator.pop(context); onDelete(msg, false); }), if (own) ListTile(leading: const Icon(Icons.delete_outline, color: red), title: const Text('Hapus untuk semua'), onTap: () { Navigator.pop(context); onDelete(msg, true); })]))), child: Align(alignment: own ? Alignment.centerRight : Alignment.centerLeft, child: Container(margin: EdgeInsets.only(top: 4, bottom: 4, left: own ? 55 : 0, right: own ? 0 : 55), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: own ? red : Colors.white, borderRadius: BorderRadius.only(topLeft: const Radius.circular(18), topRight: const Radius.circular(18), bottomLeft: Radius.circular(own ? 18 : 4), bottomRight: Radius.circular(own ? 4 : 18))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [if (msg['reply_to_id'] != null) GestureDetector(onTap: () => onJump(msg['reply_to_id']), child: Container(width: double.infinity, padding: const EdgeInsets.only(left: 8), margin: const EdgeInsets.only(bottom: 6), decoration: BoxDecoration(border: Border(left: BorderSide(color: own ? Colors.greenAccent : red, width: 3))), child: Text('Balasan', style: TextStyle(color: own ? Colors.white70 : Colors.black54, fontSize: 12))), if (msg['type'] == 'image' && content.isNotEmpty) ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(content, width: 220, height: 220, fit: BoxFit.cover)) else Text(deleted ? 'Pesan dihapus' : content, style: TextStyle(color: own ? Colors.white : Colors.black87, fontSize: 16, fontStyle: deleted ? FontStyle.italic : FontStyle.normal)), const SizedBox(height: 3), Text(DateFormat('HH:mm').format(DateTime.tryParse('${msg['created_at']}')?.toLocal() ?? DateTime.now()), style: TextStyle(color: own ? Colors.white70 : Colors.black38, fontSize: 10))])))); }
}

class SettingsPage extends StatelessWidget { final Map<String, dynamic> profile; const SettingsPage({super.key, required this.profile}); @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Pengaturan')), body: ListView(children: [ListTile(leading: const Icon(Icons.person_outline), title: const Text('Profil'), subtitle: Text('@${profile['username'] ?? ''}'), onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => EditProfilePage(profile: profile)))), const Divider(), ListTile(leading: const Icon(Icons.logout, color: red), title: const Text('Keluar', style: TextStyle(color: red)), onTap: () => supabase.auth.signOut())])); }
class EditProfilePage extends StatefulWidget { final Map<String, dynamic> profile; const EditProfilePage({super.key, required this.profile}); @override State<EditProfilePage> createState() => _EditProfilePageState(); }
class _EditProfilePageState extends State<EditProfilePage> { late final TextEditingController name, user, bio; XFile? photo; bool busy = false; @override void initState() { super.initState(); name = TextEditingController(text: widget.profile['display_name'] ?? ''); user = TextEditingController(text: widget.profile['username'] ?? ''); bio = TextEditingController(text: widget.profile['bio'] ?? ''); } @override void dispose() { name.dispose(); user.dispose(); bio.dispose(); super.dispose(); }
  Future<void> pick() async { final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85); if (x != null) setState(() => photo = x); }
  Future<void> save() async { setState(() => busy = true); try { String? url = widget.profile['avatar_url']; if (photo != null) { final path = '${supabase.auth.currentUser!.id}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg'; await supabase.storage.from('media').upload(path, File(photo!.path), fileOptions: const FileOptions(upsert: true)); url = supabase.storage.from('media').getPublicUrl(path); } await supabase.from('profiles').update({'display_name': name.text.trim(), 'username': user.text.trim().toLowerCase(), 'bio': bio.text.trim(), 'avatar_url': url}).eq('id', supabase.auth.currentUser!.id); if (mounted) Navigator.pop(context); } catch (_) { if (mounted) { setState(() => busy = false); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gagal menyimpan profil.'))); } } }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Edit profil')), body: ListView(padding: const EdgeInsets.all(22), children: [Center(child: GestureDetector(onTap: pick, child: Avatar(url: photo?.path ?? widget.profile['avatar_url'], name: name.text, size: 95, local: photo != null))), const SizedBox(height: 22), TextField(controller: name, decoration: const InputDecoration(labelText: 'Nama', border: OutlineInputBorder())), const SizedBox(height: 12), TextField(controller: user, decoration: const InputDecoration(labelText: 'Username', prefixText: '@', border: OutlineInputBorder())), const SizedBox(height: 12), TextField(controller: bio, maxLines: 4, decoration: const InputDecoration(labelText: 'Bio', border: OutlineInputBorder())), const SizedBox(height: 20), FilledButton(onPressed: busy ? null : save, child: busy ? const CircularProgressIndicator() : const Text('Simpan perubahan'))])); }
class Avatar extends StatelessWidget { final String? url, name; final double size; final bool local; const Avatar({super.key, this.url, this.name, this.size = 52, this.local = false}); @override Widget build(BuildContext c) { final n = (name ?? '?').trim(); final letter = n.isEmpty ? '?' : n[0].toUpperCase(); return CircleAvatar(radius: size / 2, backgroundColor: const Color(0xFFFFE5E9), backgroundImage: url != null && url!.isNotEmpty ? (local ? FileImage(File(url!)) : NetworkImage(url!)) as ImageProvider : null, child: url == null || url!.isEmpty ? Text(letter, style: TextStyle(color: red, fontWeight: FontWeight.w800, fontSize: size * .34)) : null); } }
