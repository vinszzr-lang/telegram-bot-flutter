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
  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Chat',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(seedColor: red),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? subscription;

  @override
  void initState() {
    super.initState();
    subscription = supabase.auth.onAuthStateChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = supabase.auth.currentUser;
    if (user == null) return const LoginPage();

    return FutureBuilder<Map<String, dynamic>?>(
      future: profileOf(user.id),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Splash();
        }
        final profile = snapshot.data;
        final username = (profile?['username'] ?? '').toString().trim();
        if (profile == null || username.isEmpty) return const UsernamePage();
        return HomePage(profile: profile);
      },
    );
  }
}

Future<Map<String, dynamic>?> profileOf(String id) async {
  try {
    final row = await supabase.from('profiles').select().eq('id', id).maybeSingle();
    if (row == null) return null;
    return Map<String, dynamic>.from(row);
  } catch (_) {
    return null;
  }
}

class Splash extends StatelessWidget {
  const Splash({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  Future<void> login() {
    return supabase.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'com.nullx.evo://login-callback',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: red,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Icon(
                  Icons.chat_bubble_rounded,
                  color: Colors.white,
                  size: 50,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Chat',
                style: TextStyle(fontSize: 38, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ngobrol cepat, simpel, dan realtime.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, fontSize: 16),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: login,
                  icon: const Icon(Icons.g_mobiledata_rounded, size: 30),
                  label: const Text(
                    'Lanjut dengan Google',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class UsernamePage extends StatefulWidget {
  const UsernamePage({super.key});

  @override
  State<UsernamePage> createState() => _UsernamePageState();
}

class _UsernamePageState extends State<UsernamePage> {
  final controller = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final username = controller.text.trim().toLowerCase().replaceAll(' ', '');
    if (username.length < 3 || !RegExp(r'^[a-z0-9_.]+$').hasMatch(username)) {
      setState(() => error = 'Username minimal 3 karakter.');
      return;
    }

    setState(() {
      busy = true;
      error = null;
    });

    try {
      final existing = await supabase
          .from('profiles')
          .select('id')
          .eq('username', username)
          .maybeSingle();
      if (existing != null) {
        if (mounted) {
          setState(() {
            busy = false;
            error = 'Username sudah dipakai.';
          });
        }
        return;
      }

      final user = supabase.auth.currentUser!;
      final metadata = user.userMetadata ?? <String, dynamic>{};
      await supabase.from('profiles').upsert({
        'id': user.id,
        'username': username,
        'display_name': metadata['full_name'] ?? username,
        'avatar_url': metadata['avatar_url'],
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Gagal menyimpan username.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Pilih username',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Orang lain menemukan kamu lewat username ini.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Username',
                  prefixText: '@',
                  errorText: error,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: busy ? null : save,
                  child: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Simpan'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final Map<String, dynamic> profile;

  const HomePage({super.key, required this.profile});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  final searchController = TextEditingController();
  List<Map<String, dynamic>> chats = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    loadChats();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> loadChats() async {
    try {
      final me = supabase.auth.currentUser!.id;
      final memberships = await supabase
          .from('conversation_members')
          .select('conversation_id')
          .eq('user_id', me);
      final ids = (memberships as List)
          .map((row) => row['conversation_id'])
          .toList();

      if (ids.isEmpty) {
        if (mounted) setState(() { chats = []; loading = false; });
        return;
      }

      final rows = await supabase
          .from('conversations')
          .select()
          .inFilter('id', ids)
          .order('updated_at', ascending: false);
      final result = <Map<String, dynamic>>[];

      for (final item in rows as List) {
        final row = Map<String, dynamic>.from(item);
        final members = await supabase
            .from('conversation_members')
            .select('user_id')
            .eq('conversation_id', row['id']);
        String? otherId;
        for (final member in members as List) {
          final id = member['user_id']?.toString();
          if (id != null && id != me) {
            otherId = id;
            break;
          }
        }
        result.add({...row, 'other_profile': otherId == null ? null : await profileOf(otherId)});
      }

      if (mounted) setState(() { chats = result; loading = false; });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> showSearch() async {
    searchController.clear();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cari username'),
        content: TextField(
          controller: searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'username',
            prefixText: '@',
          ),
          onSubmitted: (_) {
            Navigator.pop(dialogContext);
            searchUsers();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              searchUsers();
            },
            child: const Text('Cari'),
          ),
        ],
      ),
    );
  }

  Future<void> searchUsers() async {
    final q = searchController.text.trim().replaceFirst('@', '').toLowerCase();
    if (q.isEmpty) return;

    try {
      final rows = await supabase
          .from('profiles')
          .select()
          .ilike('username', '%$q%')
          .limit(20);
      if (!mounted) return;

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Cari pengguna',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              ...(rows as List).map((item) {
                final profile = Map<String, dynamic>.from(item);
                return ListTile(
                  leading: Avatar(
                    url: profile['avatar_url'],
                    name: profile['display_name'] ?? profile['username'],
                  ),
                  title: Text(profile['display_name'] ?? profile['username'] ?? ''),
                  subtitle: Text('@${profile['username'] ?? ''}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfilePage(profile: profile),
                      ),
                    );
                  },
                );
              }),
            ],
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pencarian gagal.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: bg,
        title: const Text(
          'Pesan',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(onPressed: showSearch, icon: const Icon(Icons.search_rounded)),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsPage(profile: widget.profile),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: tab == 0
          ? RefreshIndicator(
              onRefresh: loadChats,
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.only(top: 8),
                      children: [
                        if (chats.isEmpty) const EmptyChats(),
                        ...chats.map((chat) => ChatTile(data: chat)),
                      ],
                    ),
            )
          : ProfilePage(profile: widget.profile),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (index) => setState(() => tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
      floatingActionButton: tab == 0
          ? FloatingActionButton(
              backgroundColor: red,
              foregroundColor: Colors.white,
              onPressed: showSearch,
              child: const Icon(Icons.edit_rounded),
            )
          : null,
    );
  }
}

class EmptyChats extends StatelessWidget {
  const EmptyChats({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(50),
      child: Column(
        children: [
          Icon(Icons.forum_outlined, size: 70, color: red),
          SizedBox(height: 15),
          Text('Belum ada chat', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          SizedBox(height: 5),
          Text('Cari username untuk memulai percakapan.', textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class ChatTile extends StatelessWidget {
  final Map<String, dynamic> data;

  const ChatTile({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final profile = data['other_profile'] as Map<String, dynamic>?;
    final name = profile?['display_name'] ?? profile?['username'] ?? 'Chat';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
      leading: Avatar(url: profile?['avatar_url'], name: name),
      title: Text(name.toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text('@${profile?['username'] ?? ''}'),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatPage(conversation: data)),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  final Map<String, dynamic> profile;

  const ProfilePage({super.key, required this.profile});

  Future<void> openChat(BuildContext context) async {
    final me = supabase.auth.currentUser!.id;
    final target = profile['id'].toString();

    try {
      final existing = await supabase
          .from('conversation_members')
          .select('conversation_id')
          .eq('user_id', me);
      for (final item in existing as List) {
        final id = item['conversation_id'];
        final other = await supabase
            .from('conversation_members')
            .select('user_id')
            .eq('conversation_id', id)
            .eq('user_id', target)
            .maybeSingle();
        if (other != null) {
          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatPage(conversation: {'id': id, 'other_profile': profile}),
            ),
          );
          return;
        }
      }

      final conversation = await supabase
          .from('conversations')
          .insert({'type': 'direct'})
          .select()
          .single();
      await supabase.from('conversation_members').insert([
        {'conversation_id': conversation['id'], 'user_id': me},
        {'conversation_id': conversation['id'], 'user_id': target},
      ]);

      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            conversation: {'id': conversation['id'], 'other_profile': profile},
          ),
        ),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tidak bisa membuat chat.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final own = profile['id'] == supabase.auth.currentUser?.id;
    final name = profile['display_name'] ?? profile['username'] ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.all(25),
        children: [
          Center(child: Avatar(url: profile['avatar_url'], name: name, size: 110)),
          const SizedBox(height: 18),
          Center(
            child: Text(name.toString(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          ),
          Center(child: Text('@${profile['username'] ?? ''}', style: const TextStyle(color: Colors.black54))),
          if ((profile['bio'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(profile['bio'].toString(), textAlign: TextAlign.center),
            ),
          if (!own) ...[
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => openChat(context),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Mulai chat'),
            ),
          ],
        ],
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  final Map<String, dynamic> conversation;

  const ChatPage({super.key, required this.conversation});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final controller = TextEditingController();
  final scroll = ScrollController();
  final Map<String, GlobalKey> messageKeys = {};
  List<Map<String, dynamic>> messages = [];
  Map<String, dynamic>? reply;
  bool typing = false;
  Timer? typingTimer;
  RealtimeChannel? channel;

  @override
  void initState() {
    super.initState();
    loadMessages();
    channel = supabase
        .channel('chat:${widget.conversation['id']}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: widget.conversation['id'],
          ),
          callback: (_) => loadMessages(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    typingTimer?.cancel();
    if (channel != null) supabase.removeChannel(channel!);
    controller.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> loadMessages() async {
    try {
      final rows = await supabase
          .from('messages')
          .select()
          .eq('conversation_id', widget.conversation['id'])
          .order('created_at');
      final list = (rows as List).map((e) => Map<String, dynamic>.from(e)).toList();
      if (mounted) {
        setState(() => messages = list);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
        });
      }
    } catch (_) {}
  }

  void composerChanged(String value) {
    typingTimer?.cancel();
    final active = value.trim().isNotEmpty;
    if (mounted && typing != active) setState(() => typing = active);
    typingTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => typing = false);
    });
  }

  Future<void> send({String? content, String type = 'text', String? attachment}) async {
    final text = content ?? controller.text.trim();
    if (text.isEmpty && attachment == null) return;

    await supabase.from('messages').insert({
      'conversation_id': widget.conversation['id'],
      'sender_id': supabase.auth.currentUser!.id,
      'content': text,
      'type': type,
      'reply_to_id': reply?['id'],
      'attachment_url': attachment,
    });

    controller.clear();
    if (mounted) setState(() { reply = null; typing = false; });
    await loadMessages();
  }

  Future<void> pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    try {
      final path = '${supabase.auth.currentUser!.id}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      await supabase.storage.from('media').upload(
        path,
        File(picked.path),
        fileOptions: const FileOptions(upsert: true),
      );
      final url = supabase.storage.from('media').getPublicUrl(path);
      await send(type: 'image', attachment: url);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upload gambar gagal.')),
        );
      }
    }
  }

  Future<void> deleteMessage(Map<String, dynamic> message, bool everyone) async {
    final query = supabase.from('messages').update({
      'is_deleted': true,
      'content': 'Pesan dihapus',
    }).eq('id', message['id']);
    if (everyone) {
      await query.eq('sender_id', supabase.auth.currentUser!.id);
    }
    await loadMessages();
  }

  void jumpToMessage(String id) {
    final key = messageKeys[id];
    final context = key?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.conversation['other_profile'] as Map<String, dynamic>?;
    final name = profile?['display_name'] ?? profile?['username'] ?? 'Chat';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Avatar(url: profile?['avatar_url'], name: name, size: 38),
            const SizedBox(width: 10),
            Expanded(
              child: Text(name.toString(), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.all(14),
              itemCount: messages.length + (typing ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == messages.length) return const TypingBubble();
                final message = messages[index];
                final id = message['id']?.toString() ?? '$index';
                final key = messageKeys.putIfAbsent(id, GlobalKey.new);
                return KeyedSubtree(
                  key: key,
                  child: MessageBubble(
                    msg: message,
                    onReply: () => setState(() => reply = message),
                    onDelete: deleteMessage,
                    onJump: jumpToMessage,
                  ),
                );
              },
            ),
          ),
          if (reply != null)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 38,
                    color: reply!['sender_id'] == supabase.auth.currentUser?.id ? Colors.green : red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Membalas: ${reply!['content'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => reply = null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  IconButton(onPressed: pickImage, icon: const Icon(Icons.photo_outlined)),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      onChanged: composerChanged,
                      maxLines: 5,
                      minLines: 1,
                      decoration: InputDecoration(
                        hintText: 'Tulis pesan...',
                        filled: true,
                        fillColor: bg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  CircleAvatar(
                    backgroundColor: red,
                    child: IconButton(
                      onPressed: () => send(),
                      color: Colors.white,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TypingBubble extends StatelessWidget {
  const TypingBubble({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.all(6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
        child: const Text('Mengetik...', style: TextStyle(color: Colors.black54)),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final Map<String, dynamic> msg;
  final VoidCallback onReply;
  final Future<void> Function(Map<String, dynamic>, bool) onDelete;
  final ValueChanged<String> onJump;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.onReply,
    required this.onDelete,
    required this.onJump,
  });

  @override
  Widget build(BuildContext context) {
    final own = msg['sender_id'] == supabase.auth.currentUser?.id;
    final deleted = msg['is_deleted'] == true;
    final content = (msg['content'] ?? '').toString();
    final replyId = msg['reply_to_id']?.toString();
    final created = DateTime.tryParse('${msg['created_at']}')?.toLocal() ?? DateTime.now();

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 500) {
          HapticFeedback.mediumImpact();
          onReply();
        }
      },
      onLongPress: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Balas'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onReply();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Hapus untuk saya'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onDelete(msg, false);
                },
              ),
              if (own)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: red),
                  title: const Text('Hapus untuk semua'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onDelete(msg, true);
                  },
                ),
            ],
          ),
        ),
      ),
      child: Align(
        alignment: own ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(top: 4, bottom: 4, left: own ? 55 : 0, right: own ? 0 : 55),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: own ? red : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(own ? 18 : 4),
              bottomRight: Radius.circular(own ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (replyId != null)
                GestureDetector(
                  onTap: () => onJump(replyId),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(left: 8),
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: own ? Colors.greenAccent : red, width: 3)),
                    ),
                    child: Text(
                      'Balasan',
                      style: TextStyle(color: own ? Colors.white70 : Colors.black54, fontSize: 12),
                    ),
                  ),
                ),
              if (msg['type'] == 'image' && (msg['attachment_url'] ?? '').toString().isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    msg['attachment_url'].toString(),
                    width: 220,
                    height: 220,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Text(
                  deleted ? 'Pesan dihapus' : content,
                  style: TextStyle(
                    color: own ? Colors.white : Colors.black87,
                    fontSize: 16,
                    fontStyle: deleted ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              const SizedBox(height: 3),
              Text(
                DateFormat('HH:mm').format(created),
                style: TextStyle(color: own ? Colors.white70 : Colors.black38, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  final Map<String, dynamic> profile;

  const SettingsPage({super.key, required this.profile});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Profil'),
            subtitle: Text('@${profile['username'] ?? ''}'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => EditProfilePage(profile: profile)),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: red),
            title: const Text('Keluar', style: TextStyle(color: red)),
            onTap: () => supabase.auth.signOut(),
          ),
        ],
      ),
    );
  }
}

class EditProfilePage extends StatefulWidget {
  final Map<String, dynamic> profile;

  const EditProfilePage({super.key, required this.profile});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController name;
  late final TextEditingController user;
  late final TextEditingController bio;
  XFile? photo;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.profile['display_name'] ?? '');
    user = TextEditingController(text: widget.profile['username'] ?? '');
    bio = TextEditingController(text: widget.profile['bio'] ?? '');
  }

  @override
  void dispose() {
    name.dispose();
    user.dispose();
    bio.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null && mounted) setState(() => photo = picked);
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      String? url = widget.profile['avatar_url']?.toString();
      if (photo != null) {
        final path = '${supabase.auth.currentUser!.id}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await supabase.storage.from('media').upload(
          path,
          File(photo!.path),
          fileOptions: const FileOptions(upsert: true),
        );
        url = supabase.storage.from('media').getPublicUrl(path);
      }

      await supabase.from('profiles').update({
        'display_name': name.text.trim(),
        'username': user.text.trim().toLowerCase(),
        'bio': bio.text.trim(),
        'avatar_url': url,
      }).eq('id', supabase.auth.currentUser!.id);

      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gagal menyimpan profil.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profil')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Center(
            child: GestureDetector(
              onTap: pick,
              child: Avatar(
                url: photo?.path ?? widget.profile['avatar_url'],
                name: name.text,
                size: 95,
                local: photo != null,
              ),
            ),
          ),
          const SizedBox(height: 22),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Nama'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: user,
            decoration: const InputDecoration(labelText: 'Username', prefixText: '@'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: bio,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Bio'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : save,
            child: busy ? const CircularProgressIndicator() : const Text('Simpan perubahan'),
          ),
        ],
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String? url;
  final String? name;
  final double size;
  final bool local;

  const Avatar({super.key, this.url, this.name, this.size = 52, this.local = false});

  @override
  Widget build(BuildContext context) {
    final value = (name ?? '?').trim();
    final letter = value.isEmpty ? '?' : value[0].toUpperCase();
    ImageProvider<Object>? image;
    if (url != null && url!.isNotEmpty) {
      if (local) {
        image = FileImage(File(url!));
      } else {
        image = NetworkImage(url!);
      }
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: const Color(0xFFFFE5E9),
      backgroundImage: image,
      child: image == null
          ? Text(letter, style: TextStyle(color: red, fontWeight: FontWeight.w800, fontSize: size * .34))
          : null,
    );
  }
}
