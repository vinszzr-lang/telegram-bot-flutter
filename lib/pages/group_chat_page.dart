import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../services/api.dart';
import '../services/session.dart';
import '../services/socket_service.dart';
import '../utils/db.dart';
import '../widgets/verified_badge.dart';
import 'group_pages.dart';

class GroupChatPage extends StatefulWidget {
  final Session session;
  final Map<String, dynamic> group;
  const GroupChatPage({super.key, required this.session, required this.group});
  @override State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final api = Api();
  final socket = SocketService();
  final input = TextEditingController();
  final scroll = ScrollController();
  final picker = ImagePicker();
  final messages = <Map<String, dynamic>>[];
  final downloaded = <String, String>{};
  final stickers = <String>[];
  final selected = <String>{};
  Timer? pollTimer, typingTimer;
  bool _socketListenersBound = false;
  final Map<String, double> _swipeOffsets = {};
  late Map<String, dynamic> group;
  Map<String, dynamic>? replyingTo;
  bool syncing = false, sending = false, remoteTyping = false, showStickers = false;
  String? lastCursor;

  @override
  void initState() {
    super.initState();
    group = Map<String, dynamic>.from(widget.group);
    input.addListener(_inputChanged);
    _loadStickers();
    _connect();
    _load();
    pollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!socket.connected) _connect();
      _sync();
    });
  }

  void _connect() {
    final token = widget.session.token;
    if (token == null) return;
    socket.connect(Api.baseUrl, token);
    if (_socketListenersBound) return;
    _socketListenersBound = true;
    socket.on('group:message:new', _onSocketMessage);
    socket.on('group:updated', _onGroupUpdated);
    socket.on('group:typing', _onTyping);
  }

  void _onGroupUpdated(dynamic raw) {
    if (raw is! Map || raw['group'] is! Map) return;
    final g = Map<String, dynamic>.from(raw['group']);
    if (g['id']?.toString() != group['id']?.toString()) return;
    if (mounted) setState(() => group = g);
  }

  void _onTyping(dynamic raw) {
    if (raw is! Map || raw['groupId']?.toString() != group['id']?.toString()) return;
    if (raw['from']?.toString() == (widget.session.username ?? '')) return;
    final v = raw['typing'] == true;
    if (mounted && remoteTyping != v) setState(() => remoteTyping = v);
  }

  void _onSocketMessage(dynamic raw) {
    if (raw is! Map || raw['groupId']?.toString() != group['id']?.toString()) return;
    _merge([Map<String, dynamic>.from(raw)]);
    LocalCache.saveMessages('group_${group['id']}', messages);
    if (mounted) setState(() {});
    _bottom();
  }

  Future<void> _load() async {
    final local = await LocalCache.messages('group_${group['id']}');
    if (local.isNotEmpty) {
      _merge(local);
      if (mounted) setState(() {});
    }
    await _sync(full: true);
    await _markRead();
    _restoreMedia();
    _bottom(jump: true);
  }

  Future<void> _sync({bool full = false}) async {
    if (syncing || widget.session.token == null) return;
    syncing = true;
    try {
      final rows = await api.groupMessages(widget.session.token!, group['id'].toString(), since: full ? null : lastCursor);
      _merge(rows.map((e) => Map<String, dynamic>.from(e)).toList());
      if (messages.isNotEmpty) {
        final newest = messages.last['createdAt']?.toString();
        if (newest != null) lastCursor = DateTime.tryParse(newest)?.toUtc().toIso8601String();
      }
      await LocalCache.saveMessages('group_${group['id']}', messages);
      if (mounted) setState(() {});
    } catch (_) {
      // Socket is the primary realtime path; HTTP remains the recovery path.
    } finally {
      syncing = false;
    }
  }

  void _merge(List<Map<String, dynamic>> rows) {
    final map = <String, Map<String, dynamic>>{for (final m in messages) if (m['id'] != null) m['id'].toString(): m};
    for (final raw in rows) {
      final id = raw['id']?.toString();
      if (id == null || id.isEmpty) continue;
      map[id] = {...map[id] ?? <String, dynamic>{}, ...raw};
    }
    messages
      ..clear()
      ..addAll(map.values)
      ..sort((a, b) => (DateTime.tryParse(a['createdAt']?.toString() ?? '') ?? DateTime(0)).compareTo(DateTime.tryParse(b['createdAt']?.toString() ?? '') ?? DateTime(0)));
  }

  Future<void> _markRead() async {
    try { await api.markGroupRead(widget.session.token!, group['id'].toString()); } catch (_) {}
  }

  void _inputChanged() {
    final active = input.text.trim().isNotEmpty;
    socket.emit('group:typing', {'groupId': group['id'], 'typing': active});
    typingTimer?.cancel();
    if (active) typingTimer = Timer(const Duration(milliseconds: 1200), () => socket.emit('group:typing', {'groupId': group['id'], 'typing': false}));
  }

  Future<void> _sendText() async {
    final text = input.text.trim();
    if (text.isEmpty || widget.session.token == null) return;
    final replyId = replyingTo?['id']?.toString();
    input.clear();
    typingTimer?.cancel();
    socket.emit('group:typing', {'groupId': group['id'], 'typing': false});
    final reply = replyingTo;
    setState(() => replyingTo = null);
    try {
      // Do not add an optimistic local message. The socket echo and HTTP result
      // both carry the same server id and _merge() de-duplicates them.
      final r = await api.sendGroupMessage(widget.session.token!, group['id'].toString(), text, replyToId: replyId, clientMessageId: 'group-${DateTime.now().microsecondsSinceEpoch}-${text.hashCode.abs()}');
      _merge([r]);
      await LocalCache.saveMessages('group_${group['id']}', messages);
      if (mounted) setState(() {});
      _bottom();
    } catch (e) {
      if (mounted) {
        setState(() => replyingTo = reply);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengirim: $e')));
      }
    }
  }

  Future<void> _pickMedia({required String type}) async {
    XFile? x;
    if (type == 'image') {
      x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 2400, maxHeight: 2400);
    } else if (type == 'video') {
      x = await picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 10));
    } else {
      final f = await FilePicker.pickFile();
      if (f?.path != null) x = XFile(f!.path!, name: f.name);
    }
    if (x == null) return;
    await _sendFile(File(x.path), x.name, type);
  }

  Future<void> _sendFile(File file, String name, String type) async {
    if (!await file.exists() || widget.session.token == null) return;
    if (await file.length() > 50 * 1024 * 1024) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Maksimal 50 MB.')));
      return;
    }
    setState(() => sending = true);
    final replyId = replyingTo?['id']?.toString();
    try {
      final r = await api.uploadGroupMedia(widget.session.token!, group['id'].toString(), file, type: type, replyToId: replyId, clientMessageId: 'group-media-${DateTime.now().microsecondsSinceEpoch}-${name.hashCode.abs()}');
      _merge([r]);
      final id = r['id']?.toString();
      if (id != null && (type == 'image' || type == 'video' || type == 'sticker')) {
        final local = await _localMedia(r);
        await local.parent.create(recursive: true);
        await file.copy(local.path);
        downloaded[id] = local.path;
      }
      replyingTo = null;
      await LocalCache.saveMessages('group_${group['id']}', messages);
      if (mounted) setState(() {});
      _bottom();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengirim $name: $e')));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<Directory> _stickerDir() async {
    final base = await getApplicationDocumentsDirectory();
    final safe = (widget.session.username ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final d = Directory('${base.path}/chatwithu_stickers/$safe');
    await d.create(recursive: true);
    return d;
  }

  Future<void> _loadStickers() async {
    final p = await SharedPreferences.getInstance();
    final values = p.getStringList('chatwithu_stickers_${(widget.session.username ?? '')}') ?? <String>[];
    final valid = <String>[];
    for (final x in values) { if (await File(x).exists()) { valid.add(x); } }
    if (mounted) setState(() { stickers..clear()..addAll(valid); });
    if (valid.length != values.length) await p.setStringList('chatwithu_stickers_${(widget.session.username ?? '')}', valid);
  }

  Future<void> _saveSticker(String path) async {
    final p = await SharedPreferences.getInstance();
    final key = 'chatwithu_stickers_${(widget.session.username ?? '')}';
    final v = [...(p.getStringList(key) ?? <String>[])];
    if (!v.contains(path)) v.add(path);
    await p.setStringList(key, v);
    if (mounted) setState(() { stickers..clear()..addAll(v); });
  }

  Future<void> _makeSticker() async {
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 95, maxWidth: 1200, maxHeight: 1200);
    if (x == null) return;
    final dir = await _stickerDir();
    final path = '${dir.path}/sticker_${DateTime.now().microsecondsSinceEpoch}.png';
    try {
      // Keep the original aspect ratio; the sticker bubble will contain it.
      await File(x.path).copy(path);
      await _saveSticker(path);
      if (mounted) setState(() => showStickers = true);
    } catch (_) {}
  }

  Future<void> _sendSticker(String path) async {
    await _sendFile(File(path), path.split('/').last, 'sticker');
  }

  Future<File> _localMedia(Map<String, dynamic> m) async {
    final d = await getApplicationDocumentsDirectory();
    final dir = Directory('${d.path}/chatwithu_group_media');
    final name = (m['fileName'] ?? 'media').toString().replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    return File('${dir.path}/${m['id']}_$name');
  }

  Future<void> _restoreMedia() async {
    for (final m in messages) {
      if (!['image', 'video', 'sticker'].contains(m['type'])) continue;
      final f = await _localMedia(m);
      if (await f.exists()) downloaded[m['id'].toString()] = f.path;
    }
    if (mounted) setState(() {});
  }

  Future<void> _downloadMedia(Map<String, dynamic> m) async {
    final id = m['id']?.toString() ?? '';
    if (id.isEmpty || downloaded.containsKey(id)) return;
    try {
      final r = await api.downloadMedia(widget.session.token!, id);
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final f = await _localMedia(m);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(r.bodyBytes, flush: true);
      downloaded[id] = f.path;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengambil media: $e')));
    }
  }

  Future<void> _reply(Map<String, dynamic> m) async {
    setState(() => replyingTo = m);
    FocusScope.of(context).requestFocus(FocusNode());
  }

  void _toggleSelected(Map<String, dynamic> m) {
    final id = m['id']?.toString();
    if (id == null) return;
    setState(() {
      if (selected.contains(id)) { selected.remove(id); } else { selected.add(id); }
    });
  }

  void _hapticLongPress() { const MethodChannel('xchat/notifications').invokeMethod('vibrate500').catchError((_) => null); }
  void _startSelection(Map<String, dynamic> m) {
    if (selected.isEmpty) {
      _hapticLongPress();
      final id = m['id']?.toString();
      if (id != null) setState(() => selected.add(id));
    } else {
      _toggleSelected(m);
    }
  }

  Future<void> _copySelected() async {
    final texts = messages.where((m) => selected.contains(m['id']?.toString()) && m['type'] == 'text' && m['deleted'] != true).map((m) => m['message']?.toString() ?? '').where((x) => x.isNotEmpty).toList();
    if (texts.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: texts.join('\n')));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pesan disalin')));
    setState(() => selected.clear());
  }

  Future<void> _deleteSelected() async {
    final ids = selected.toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      final m = messages.firstWhere((x) => x['id']?.toString() == id, orElse: () => {});
      if (m.isEmpty || m['senderUsername']?.toString() != (widget.session.username ?? '')) continue;
      try { await api.deleteGroupMessage(widget.session.token!, group['id'].toString(), id); } catch (_) {}
    }
    selected.clear();
    await _sync(full: true);
    if (mounted) setState(() {});
  }

  void _bottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients) return;
      final t = scroll.position.maxScrollExtent;
      if (jump) { scroll.jumpTo(t); } else { scroll.animateTo(t, duration: const Duration(milliseconds: 140), curve: Curves.easeOut); }
    });
  }

  String _time(dynamic v) {
    final d = DateTime.tryParse(v?.toString() ?? '')?.toLocal();
    return d == null ? '' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _memberSubtitle() {
    final members = List<dynamic>.from(group['members'] ?? const []);
    return members.map((e) => (e['name'] ?? e['username']).toString()).take(4).join(', ');
  }

  String _senderName(Map<String, dynamic> m) {
    if (m['senderUsername']?.toString() == (widget.session.username ?? '')) return 'Anda';
    return (m['senderName'] ?? m['senderUsername'] ?? 'Pengguna').toString();
  }

  String _replyLabel(Map<String, dynamic> m) {
    final u = m['senderUsername']?.toString();
    if (u == (widget.session.username ?? '')) return 'Anda';
    final members = List<dynamic>.from(group['members'] ?? const []);
    for (final raw in members) { if (raw is Map && raw['username']?.toString() == u) return (raw['name'] ?? u ?? 'Pengguna').toString(); }
    return (m['senderName'] ?? u ?? 'Pengguna').toString();
  }

  Widget _quoted(Map<String, dynamic>? reply) {
    if (reply == null) return const SizedBox.shrink();
    final type = reply['type']?.toString() ?? 'text';
    final text = type == 'text' ? (reply['message'] ?? '').toString() : type == 'image' ? 'Foto' : type == 'video' ? 'Video' : type == 'sticker' ? 'Sticker' : type == 'poll' ? 'Polling' : 'File';
    return Container(width: double.infinity, margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.fromLTRB(9, 6, 8, 6), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .16), borderRadius: BorderRadius.circular(8), border: const Border(left: BorderSide(color: Color(0xFF58D68D), width: 3))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_replyLabel(reply), style: const TextStyle(color: Color(0xFF62D696), fontWeight: FontWeight.w800, fontSize: 12)), Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12))]));
  }

  Widget _messageMedia(Map<String, dynamic> m) {
    final id = m['id']?.toString() ?? '';
    final path = downloaded[id];
    final type = m['type']?.toString() ?? '';
    if (path == null) {
      return GestureDetector(onTap: () => _downloadMedia(m), child: Container(width: 250, height: 190, decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)), child: const Center(child: Icon(Icons.download_rounded, size: 38))));
    }
    if (type == 'video') return GestureDetector(onTap: () => _openMedia(m), child: _InlineVideo(path: path, maxWidth: 300, maxHeight: 420));
    return GestureDetector(onTap: () => _openMedia(m), child: _AspectImage(path: path, maxWidth: 300, maxHeight: 420));
  }

  Future<void> _openMedia(Map<String, dynamic> m) async {
    final id = m['id']?.toString() ?? '';
    if (!downloaded.containsKey(id)) await _downloadMedia(m);
    final path = downloaded[id];
    if (path == null || !mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => _GroupMediaViewer(path: path, video: m['type'] == 'video')));
  }

  Widget _pollBubble(Map<String, dynamic> m) {
    final p = Map<String, dynamic>.from(m['poll'] as Map? ?? {});
    final options = List<dynamic>.from(p['options'] ?? const []);
    final myVote = p['myVote']?.toString();
    final total = options.fold<int>(0, (s, x) => s + (int.tryParse('${x['votes'] ?? 0}') ?? 0));
    return Container(width: 290, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF1B2529), borderRadius: BorderRadius.circular(15)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text((p['question'] ?? m['message'] ?? 'Polling').toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 8), ...options.map((o) { final id = o['id'].toString(); final votes = int.tryParse('${o['votes'] ?? 0}') ?? 0; final pct = total == 0 ? 0.0 : votes / total; final chosen = myVote == id; final percent = total == 0 ? 0 : ((votes / total) * 100).round(); return Padding(padding: const EdgeInsets.only(bottom: 7), child: InkWell(onTap: myVote == null ? () => _votePoll(m, id) : null, borderRadius: BorderRadius.circular(11), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), color: chosen ? const Color(0xFF205F49) : const Color(0xFF253136)), child: Column(children: [Row(children: [Expanded(child: Text(o['text'].toString())), Text('$votes • $percent%', style: const TextStyle(color: Colors.white60))]), const SizedBox(height: 5), ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: pct, minHeight: 4, backgroundColor: Colors.white10))])))); }), if (myVote != null) const Text('Anda sudah memilih', style: TextStyle(fontSize: 11, color: Colors.white54))]));
  }

  Future<void> _votePoll(Map<String, dynamic> m, String optionId) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Yakin Memilih Ini?'), content: const Text('Pilihan hanya bisa dipilih satu kali.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK'))])) ?? false;
    if (!ok) return;
    try {
      final r = await api.voteGroupPoll(widget.session.token!, group['id'].toString(), m['id'].toString(), optionId);
      _merge([r]);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _bubble(Map<String, dynamic> m) {
    final id = m['id']?.toString() ?? '';
    final mine = m['senderUsername']?.toString() == (widget.session.username ?? '');
    final type = m['type']?.toString() ?? 'text';
    final isSelected = selected.contains(id);
    final deleted = m['deleted'] == true;
    Widget body;
    if (deleted) {
      body = Row(mainAxisSize: MainAxisSize.min, children: const [Icon(Icons.block_rounded, size: 15, color: Colors.white38), SizedBox(width: 5), Text('Pesan ini telah dihapus', style: TextStyle(color: Colors.white38, fontStyle: FontStyle.italic))]);
    } else if (type == 'poll') {
      body = _pollBubble(m);
    } else if (type == 'image' || type == 'video' || type == 'sticker') {
      body = _messageMedia(m);
    } else if (type == 'file') {
      body = GestureDetector(onTap: () => _downloadMedia(m), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.insert_drive_file_outlined, size: 34), const SizedBox(width: 9), Flexible(child: Text((m['fileName'] ?? 'File').toString(), maxLines: 2, overflow: TextOverflow.ellipsis)), const Icon(Icons.download_rounded, size: 19)]));
    } else {
      body = Text(m['message']?.toString() ?? '', style: const TextStyle(fontSize: 15, height: 1.25));
    }
    final children = <Widget>[];
    if (!mine && type != 'poll') children.add(Row(children: [_avatar(m), const SizedBox(width: 7), Flexible(child: Text(_senderName(m), style: const TextStyle(color: Color(0xFF75D6A0), fontSize: 14, fontWeight: FontWeight.w800))), if (m['senderVerified'] == true) const Padding(padding: EdgeInsets.only(left: 4), child: VerifiedBadge(size: 14))]));
    if (!mine && type != 'poll') children.add(const SizedBox(height: 4));
    children.add(_quoted(m['replyTo'] is Map ? Map<String, dynamic>.from(m['replyTo']) : null));
    children.add(body);
    children.add(const SizedBox(height: 2));
    children.add(Row(mainAxisSize: MainAxisSize.min, children: [Text(_time(m['createdAt']), style: const TextStyle(fontSize: 10, color: Colors.white54)), if (mine) ...[const SizedBox(width: 3), Icon(m['status'] == 'read' ? Icons.done_all : Icons.done_all, size: 15, color: m['status'] == 'read' ? const Color(0xFF64B5F6) : Colors.white54)]]));
    final bubble = Container(constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .84), margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.fromLTRB(10, 8, 8, 6), decoration: BoxDecoration(color: isSelected ? const Color(0xFF365C4D) : mine ? const Color(0xFF286A54) : const Color(0xFF20282C), borderRadius: BorderRadius.circular(13)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children));
    return _GroupSwipeReply(
      offset: _swipeOffsets[id] ?? 0,
      onOffsetChanged: (v) => setState(() => _swipeOffsets[id] = v),
      onReply: () => _reply(m),
      onLongPress: () => _startSelection(m),
      onTap: selected.isNotEmpty ? () => _toggleSelected(m) : null,
      child: Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: bubble),
    );
  }

  Widget _avatar(Map<String, dynamic> m) {
    final a = (m['senderAvatarUrl'] ?? '').toString();
    final n = _senderName(m);
    return CircleAvatar(radius: 15, backgroundImage: a.isNotEmpty ? NetworkImage(a) : null, child: a.isEmpty ? Text(n.isEmpty ? '?' : n[0].toUpperCase(), style: const TextStyle(fontSize: 11)) : null);
  }

  Future<void> _createPoll() async {
    final q = TextEditingController();
    final options = <TextEditingController>[
      TextEditingController(),
      TextEditingController(),
    ];

    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Buat Polling'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: q,
                      decoration: const InputDecoration(labelText: 'Judul polling'),
                    ),
                    const SizedBox(height: 10),
                    ...List.generate(options.length, (i) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: options[i],
                                decoration: InputDecoration(labelText: 'Pilihan ${i + 1}'),
                              ),
                            ),
                            if (i >= 2)
                              IconButton(
                                onPressed: () {
                                  final removed = options.removeAt(i);
                                  removed.dispose();
                                  setDialogState(() {});
                                },
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                          ],
                        ),
                      );
                    }),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          options.add(TextEditingController());
                          setDialogState(() {});
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Tambah pilihan'),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Batal'),
                ),
                FilledButton(
                  onPressed: () {
                    final out = options
                        .map((x) => x.text.trim())
                        .where((x) => x.isNotEmpty)
                        .toList();
                    if (q.text.trim().isNotEmpty && out.length >= 2) {
                      Navigator.pop(dialogContext, out);
                    }
                  },
                  child: const Text('Buat'),
                ),
              ],
            );
          },
        );
      },
    );

    final question = q.text.trim();
    q.dispose();
    for (final controller in options) {
      controller.dispose();
    }
    if (result == null || question.isEmpty || !mounted) return;

    try {
      final r = await api.createGroupPoll(
        widget.session.token!,
        group['id'].toString(),
        question,
        result,
      );
      _merge([r]);
      if (mounted) {
        setState(() {});
        _bottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Widget _stickerTray() {
    return Container(
      height: 145,
      color: const Color(0xFF151C20),
      child: Row(
        children: [
          IconButton(onPressed: _makeSticker, icon: const Icon(Icons.add_circle_outline)),
          Expanded(
            child: stickers.isEmpty
                ? const Center(child: Text('Buat sticker dari galeri'))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(8),
                    itemCount: stickers.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      return GestureDetector(
                        onTap: () => _sendSticker(stickers[i]),
                        child: Container(
                          width: 110,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF20282C),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Image.file(File(stickers[i]), fit: BoxFit.contain),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (replyingTo != null)
          Container(
            color: const Color(0xFF121B1E),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(child: _quoted(replyingTo)),
                IconButton(
                  onPressed: () => setState(() => replyingTo = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        if (showStickers) _stickerTray(),
        Container(
          color: const Color(0xEE10171A),
          padding: const EdgeInsets.fromLTRB(5, 6, 7, 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                onPressed: sending ? null : _attachments,
                icon: const Icon(Icons.add_circle_outline),
              ),
              IconButton(
                onPressed: sending ? null : () => setState(() => showStickers = !showStickers),
                icon: const Icon(Icons.sticky_note_2_outlined),
              ),
              Expanded(
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: 'Pesan grup',
                    filled: true,
                    fillColor: const Color(0xFF1B2529),
                    border: OutlineInputBorder(
                      borderSide: BorderSide.none,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Polling',
                onPressed: sending ? null : _createPoll,
                icon: const Icon(Icons.poll_outlined),
              ),
              const SizedBox(width: 3),
              Material(
                color: const Color(0xFF20C76B),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: sending ? null : _sendText,
                  customBorder: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.send_rounded, color: Colors.black, size: 21),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _attachments() async {
    final choice = await showModalBottomSheet<String>(context: context, backgroundColor: const Color(0xFF10171A), builder: (c) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 18), child: Column(mainAxisSize: MainAxisSize.min, children: [const Align(alignment: Alignment.centerLeft, child: Text('Kirim lampiran', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800))), const SizedBox(height: 12), Row(children: [_choice(c, Icons.photo_rounded, 'Foto', 'image'), _choice(c, Icons.videocam_rounded, 'Video', 'video'), _choice(c, Icons.description_rounded, 'File', 'file'), _choice(c, Icons.sticky_note_2_outlined, 'Sticker', 'sticker')])]))));
    if (choice == null) return;
    if (choice == 'sticker') { setState(() => showStickers = true); return; }
    await _pickMedia(type: choice);
  }

  Widget _choice(BuildContext c, IconData icon, String label, String value) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: InkWell(onTap: () => Navigator.pop(c, value), borderRadius: BorderRadius.circular(16), child: Container(height: 82, decoration: BoxDecoration(color: const Color(0xFF1B2529), borderRadius: BorderRadius.circular(16)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon), const SizedBox(height: 5), Text(label)])))));

  PreferredSizeWidget _selectionBar() => AppBar(backgroundColor: const Color(0xFF10171A), leading: IconButton(onPressed: () => setState(() => selected.clear()), icon: const Icon(Icons.close)), title: Text('${selected.length} dipilih'), actions: [if (messages.where((m) => selected.contains(m['id']?.toString()) && m['type'] == 'text').isNotEmpty) IconButton(onPressed: _copySelected, icon: const Icon(Icons.copy_outlined)), IconButton(onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline))]);

  @override
  Widget build(BuildContext context) {
    final appBar = selected.isNotEmpty
        ? _selectionBar()
        : AppBar(
            backgroundColor: const Color(0xFF10171A),
            title: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GroupInfoPage(
                      session: widget.session,
                      groupId: group['id'].toString(),
                    ),
                  ),
                );
              },
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFF2D2039),
                    backgroundImage: (group['avatarUrl'] ?? '').toString().isNotEmpty
                        ? NetworkImage(group['avatarUrl'].toString())
                        : null,
                    child: (group['avatarUrl'] ?? '').toString().isEmpty
                        ? Text(
                            group['name'].toString().isEmpty
                                ? '?'
                                : group['name'].toString()[0].toUpperCase(),
                          )
                        : null,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group['name'].toString(),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                          overflow: TextOverflow.ellipsis,
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: remoteTyping
                              ? const Text(
                                  'Mengetik...',
                                  style: TextStyle(fontSize: 11, color: Color(0xFF5FD18A)),
                                )
                              : Text(
                                  _memberSubtitle(),
                                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              IconButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GroupInfoPage(
                        session: widget.session,
                        groupId: group['id'].toString(),
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.info_outline_rounded),
              ),
            ],
          );

    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      appBar: appBar,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset('assets/xchat_background.jpg', fit: BoxFit.cover),
          ),
          Positioned.fill(
            child: Container(color: const Color(0xD9080D10)),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 76),
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                itemCount: messages.length,
                itemBuilder: (_, i) => _bubble(messages[i]),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(top: false, child: _composer()),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() { pollTimer?.cancel(); typingTimer?.cancel(); socket.emit('group:typing', {'groupId': group['id'], 'typing': false}); socket.disconnect(); input.removeListener(_inputChanged); input.dispose(); scroll.dispose(); super.dispose(); }
}

class _AspectImage extends StatelessWidget {
  final String path; final double maxWidth, maxHeight;
  const _AspectImage({required this.path, required this.maxWidth, required this.maxHeight});
  @override Widget build(BuildContext context) => ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight), child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.file(File(path), fit: BoxFit.contain, filterQuality: FilterQuality.high)));
}

class _InlineVideo extends StatefulWidget {
  final String path; final double maxWidth, maxHeight;
  const _InlineVideo({required this.path, required this.maxWidth, required this.maxHeight});
  @override State<_InlineVideo> createState() => _InlineVideoState();
}
class _InlineVideoState extends State<_InlineVideo> {
  late VideoPlayerController c;
  @override void initState() { super.initState(); c = VideoPlayerController.file(File(widget.path))..initialize().then((_) { if (mounted) setState(() {}); }); }
  @override void dispose() { c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) { if (!c.value.isInitialized) return const SizedBox(width: 250, height: 180, child: Center(child: CircularProgressIndicator())); return Stack(alignment: Alignment.center, children: [ConstrainedBox(constraints: BoxConstraints(maxWidth: widget.maxWidth, maxHeight: widget.maxHeight), child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))), IconButton(onPressed: () => setState(() => c.value.isPlaying ? c.pause() : c.play()), icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white, size: 48))]); }
}

class _GroupMediaViewer extends StatelessWidget {
  final String path; final bool video;
  const _GroupMediaViewer({required this.path, required this.video});
  @override Widget build(BuildContext context) => Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black), body: Center(child: video ? _ViewerVideo(path: path) : InteractiveViewer(constrained: false, minScale: .5, maxScale: 6, boundaryMargin: const EdgeInsets.all(double.infinity), child: Container(color: Colors.black, padding: const EdgeInsets.all(12), child: Image.file(File(path), fit: BoxFit.contain, filterQuality: FilterQuality.high)))));
}
class _ViewerVideo extends StatefulWidget { final String path; const _ViewerVideo({required this.path}); @override State<_ViewerVideo> createState() => _ViewerVideoState(); }
class _ViewerVideoState extends State<_ViewerVideo> { late VideoPlayerController c; @override void initState(){super.initState();c=VideoPlayerController.file(File(widget.path))..initialize().then((_){if(mounted){setState((){});c.play();}});} @override void dispose(){c.dispose();super.dispose();} @override Widget build(BuildContext context)=>c.value.isInitialized?Stack(alignment:Alignment.center,children:[AspectRatio(aspectRatio:c.value.aspectRatio,child:VideoPlayer(c)),IconButton(onPressed:(){setState(()=>c.value.isPlaying?c.pause():c.play());},icon:Icon(c.value.isPlaying?Icons.pause_circle:Icons.play_circle,color:Colors.white,size:60))]):const Center(child:CircularProgressIndicator()); }


class _GroupSwipeReply extends StatefulWidget {
  final double offset;
  final ValueChanged<double> onOffsetChanged;
  final VoidCallback onReply;
  final VoidCallback onLongPress;
  final VoidCallback? onTap;
  final Widget child;
  const _GroupSwipeReply({required this.offset, required this.onOffsetChanged, required this.onReply, required this.onLongPress, required this.onTap, required this.child});
  @override State<_GroupSwipeReply> createState()=>_GroupSwipeReplyState();
}
class _GroupSwipeReplyState extends State<_GroupSwipeReply> with SingleTickerProviderStateMixin {
  late AnimationController c; double drag=0;
  @override void initState(){super.initState();c=AnimationController(vsync:this,duration:const Duration(milliseconds:180));}
  @override void dispose(){c.dispose();super.dispose();}
  void snap(){final start=drag;c..reset()..addListener((){widget.onOffsetChanged(start*(1-c.value));})..forward();}
  @override Widget build(BuildContext context){final shown=drag>0?drag:widget.offset;return GestureDetector(
    behavior:HitTestBehavior.translucent,onLongPress:widget.onLongPress,onTap:widget.onTap,
    onHorizontalDragUpdate:(d){if(d.delta.dx<=0&&drag<=0)return;drag=(drag+d.delta.dx).clamp(0.0,96.0);widget.onOffsetChanged(drag);},
    onHorizontalDragEnd:(_){if(drag>=64)widget.onReply();snap();},
    child:Stack(children:[Positioned.fill(child:Align(alignment:Alignment.centerLeft,child:Opacity(opacity:(shown/64).clamp(0.0,1.0),child:const Padding(padding:EdgeInsets.only(left:8),child:Icon(Icons.reply_rounded,color:Color(0xFF62D696),size:22))))),Transform.translate(offset:Offset(shown,0),child:widget.child)]));}
}
