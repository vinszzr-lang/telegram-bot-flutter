import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/session.dart';
import '../services/socket_service.dart';
import '../utils/navigation.dart';
import '../widgets/verified_badge.dart';
import 'add_contact_page.dart';
import 'banned_page.dart';
import 'chat_page.dart';
import 'profile_page.dart';

class HomePage extends StatefulWidget {
  final Session session;
  const HomePage({super.key, required this.session});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with RouteAware {
  final api = Api();
  final Map<String, Map<String, dynamic>> contactMap = {};
  Timer? pollTimer;
  SocketService? socket;
  bool loading = true;
  bool syncing = false;
  bool routeSubscribed = false;
  String search = '';

  @override
  void initState() {
    super.initState();
    refresh();
    socket = SocketService(widget.session.token!, (_) => syncFast(), (_) {},
      onBanned: _showBanned,
      onProfileUpdated: _profileUpdated,
    )..connect();
    // Socket.IO is the immediate path. This 400 ms heartbeat is a fallback and
    // also catches changes made from the admin website without a manual refresh.
    _startPolling();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!routeSubscribed) {
      final route = ModalRoute.of(context);
      if (route is PageRoute) {
        chatWithURouteObserver.subscribe(this, route);
        routeSubscribed = true;
      }
    }
  }

  void _startPolling() {
    pollTimer?.cancel();
    pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) => syncFast());
  }

  void _stopPolling() {
    pollTimer?.cancel();
    pollTimer = null;
  }

  @override
  void didPushNext() => _stopPolling();

  @override
  void didPopNext() => _startPolling();

  Future<void> refresh() => syncFast(forceLoading: true);

  Future<void> syncFast({bool forceLoading = false}) async {
    if (syncing || widget.session.token == null) return;
    syncing = true;
    if (forceLoading && mounted) setState(() => loading = true);
    try {
      final data = await api.sync(widget.session.token!);
      final user = Map<String, dynamic>.from(data['user'] ?? {});
      await widget.session.updateUser(user);
      final next = <String, Map<String, dynamic>>{};
      _mergeInto(next, data['contacts']);
      _mergeInto(next, data['inbox']);
      contactMap
        ..clear()
        ..addAll(next);
      if (mounted) setState(() => loading = false);
    } on ApiException catch (e) {
      if (e.status == 403) _showBanned();
      if (mounted) setState(() => loading = false);
    } catch (_) {
      if (mounted) setState(() => loading = false);
    } finally {
      syncing = false;
    }
  }

  void _mergeInto(Map<String, Map<String, dynamic>> target, dynamic raw) {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final c = Map<String, dynamic>.from(item);
      final u = c['username']?.toString();
      if (u == null || u.isEmpty) continue;
      target[u] = {...?target[u], ...c};
    }
  }

  void _profileUpdated(Map<String, dynamic> p) async {
    final oldUsername = p['oldUsername']?.toString();
    final newUsername = p['username']?.toString();
    if (oldUsername != null && contactMap.containsKey(oldUsername) && newUsername != null && newUsername.isNotEmpty) {
      final old = contactMap.remove(oldUsername)!;
      contactMap[newUsername] = {...old, ...p, 'username': newUsername};
    } else if (newUsername != null && contactMap.containsKey(newUsername)) {
      contactMap[newUsername] = {...contactMap[newUsername]!, ...p};
    }
    if (oldUsername == widget.session.username || newUsername == widget.session.username) {
      await widget.session.updateUser(p);
    }
    if (mounted) setState(() {});
  }

  void _showBanned() {
    if (!mounted) return;
    pollTimer?.cancel();
    socket?.dispose();
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => BannedPage(session: widget.session)), (_) => false);
  }

  @override
  void dispose() {
    _stopPolling();
    if (routeSubscribed) chatWithURouteObserver.unsubscribe(this);
    socket?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = contactMap.values.where((c) {
      final text = '${c['name'] ?? ''} ${c['displayName'] ?? ''} ${c['username'] ?? ''}'.toLowerCase();
      return text.contains(search);
    }).toList()..sort((a, b) => (b['lastMessageAt'] ?? '').toString().compareTo((a['lastMessageAt'] ?? '').toString()));

    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080D10),
        title: const Text('ChatWithU', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
        actions: [IconButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfilePage(session: widget.session))).then((_) => refresh()), icon: const Icon(Icons.more_vert))],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: TextField(
              onChanged: (v) => setState(() => search = v.toLowerCase()),
              decoration: InputDecoration(hintText: 'Cari...', prefixIcon: const Icon(Icons.search), filled: true, fillColor: const Color(0xFF20272B), border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
            ),
          ),
          Expanded(child: loading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: refresh, child: ListView.builder(physics: const AlwaysScrollableScrollPhysics(), itemCount: filtered.length, itemBuilder: (_, i) => _tile(filtered[i])))),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        onPressed: () async {
          final ok = await Navigator.push(context, MaterialPageRoute(builder: (_) => AddContactPage(session: widget.session)));
          if (ok == true) refresh();
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> c) {
    final u = (c['username'] ?? '').toString();
    final name = (c['name'] ?? c['displayName'] ?? u).toString();
    final avatar = (c['avatarUrl'] ?? '').toString();
    final verified = c['verified'] == true;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(radius: 25, backgroundColor: const Color(0xFF2A1D38), backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null, child: avatar.isEmpty ? Text(name.isEmpty ? '?' : name[0].toUpperCase()) : null),
      title: Row(children: [Flexible(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)), if (verified) const Padding(padding: EdgeInsets.only(left: 5), child: VerifiedBadge())]),
      subtitle: Text(c['lastMessage']?.toString().isNotEmpty == true ? c['lastMessage'].toString() : '@$u', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [if (c['lastMessageAt'] != null) Text(_listTime(c['lastMessageAt']), style: const TextStyle(fontSize: 11, color: Colors.white54)), if ((c['unread'] ?? 0) > 0) Container(margin: const EdgeInsets.only(top: 5), padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3), decoration: BoxDecoration(color: const Color(0xFF6C4DFF), borderRadius: BorderRadius.circular(20)), child: Text('${c['unread']}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)))]),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(session: widget.session, contact: c))).then((_) => refresh()),
    );
  }

  String _listTime(dynamic value) {
    final d = DateTime.tryParse(value.toString())?.toLocal();
    if (d == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (diff == 1) return 'Kemarin';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}
