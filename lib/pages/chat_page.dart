import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:saver_gallery/saver_gallery.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/api.dart';
import '../services/session.dart';
import '../utils/db.dart';
import '../widgets/verified_badge.dart';
import 'banned_page.dart';

class ChatPage extends StatefulWidget {
  final Session session;
  final Map<String, dynamic> contact;
  const ChatPage({super.key, required this.session, required this.contact});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late String username;
  late String displayName;
  String avatarUrl = '';
  bool verified = false;
  final api = Api();
  final input = TextEditingController();
  final scroll = ScrollController();
  final picker = ImagePicker();
  Timer? pollTimer;
  Timer? profileTimer;
  bool syncingProfile = false;
  List<Map<String, dynamic>> messages = [];
  bool sendingMedia = false;
  bool syncing = false;
  String? lastCursor;

  @override
  void initState() {
    super.initState();
    username = widget.contact['username'].toString();
    displayName = (widget.contact['name'] ?? widget.contact['displayName'] ?? username).toString();
    avatarUrl = (widget.contact['avatarUrl'] ?? '').toString();
    verified = widget.contact['verified'] == true;
    load();
    // Socket.IO is intentionally not used. The chat stays near-real-time by
    // polling the incremental messages endpoint once per second.
    pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => syncMessages());
    // Keep the verified badge live. If an account is verified/unverified on
    // the server while this chat is open, the blue badge updates immediately
    // without requiring a manual refresh or leaving/re-entering the chat.
    profileTimer = Timer.periodic(const Duration(seconds: 1), (_) => syncContactProfile());
  }

  Future<void> load() async {
    await LocalCache.markRead(username, DateTime.now().toUtc().toIso8601String());
    final local = await LocalCache.messages(username);
    if (mounted && local.isNotEmpty) setState(() => messages = local);
    await syncMessages(full: true);
    _bottom(jump: true);
  }

  Future<void> syncContactProfile() async {
    if (syncingProfile || widget.session.token == null) return;
    syncingProfile = true;
    try {
      final user = await api.findUser(widget.session.token!, username);
      final nextVerified = user['verified'] == true;
      final nextName = (user['name'] ?? user['displayName'] ?? displayName).toString();
      final nextAvatar = (user['avatarUrl'] ?? avatarUrl).toString();
      final changed = nextVerified != verified || nextName != displayName || nextAvatar != avatarUrl;
      if (changed && mounted) {
        setState(() {
          verified = nextVerified;
          displayName = nextName;
          avatarUrl = nextAvatar;
        });
      }
      // Keep the contact map passed around by HomePage current too, so when
      // the user goes back the list does not need a manual refresh to reflect
      // the badge state.
      widget.contact['verified'] = nextVerified;
      widget.contact['name'] = nextName;
      widget.contact['displayName'] = nextName;
      widget.contact['avatarUrl'] = nextAvatar;
    } on ApiException catch (e) {
      if (e.status == 403) _showBanned();
    } catch (_) {
      // A temporary profile request failure must never interrupt chat polling.
    } finally {
      syncingProfile = false;
    }
  }

  Future<void> syncMessages({bool full = false}) async {
    if (syncing || widget.session.token == null) return;
    syncing = true;
    try {
      final remote = await api.messages(widget.session.token!, username, since: full ? null : lastCursor);
      final changed = _mergeMessages(remote.map((e) => Map<String, dynamic>.from(e)).toList());
      final all = messages;
      if (all.isNotEmpty) {
        DateTime? newest;
        for (final m in all) {
          final raw = m['updatedAt'] ?? m['createdAt'];
          final d = DateTime.tryParse(raw?.toString() ?? '');
          if (d != null && (newest == null || d.isAfter(newest))) newest = d;
        }
        if (newest != null) {
          final readIso = newest.toUtc().toIso8601String();
          lastCursor = readIso;
          await LocalCache.markRead(username, readIso);
        }
      }
      await LocalCache.saveMessages(username, messages);
      if (changed) {
        if (mounted) setState(() {});
        if (remote.isNotEmpty) _bottom();
      }
    } on ApiException catch (e) {
      if (e.status == 403) _showBanned();
    } catch (_) {
      // Polling is the realtime transport used by this client.
    } finally {
      syncing = false;
    }
  }

  bool _mergeMessages(List<Map<String, dynamic>> incoming) {
    if (incoming.isEmpty) return false;

    final byId = <String, Map<String, dynamic>>{};
    for (final m in messages) {
      final id = m['id']?.toString();
      if (id != null) byId[id] = m;
    }

    bool changed = false;
    for (final incomingMessage in incoming) {
      final m = Map<String, dynamic>.from(incomingMessage);
      final id = m['id']?.toString();
      if (id == null || id.isEmpty) continue;

      if (byId.containsKey(id)) {
        final old = byId[id]!;
        final merged = {...old, ...m};
        if (merged.toString() != old.toString()) changed = true;
        byId[id] = merged;
        continue;
      }

      // If the 1-second poll returns the canonical server message before the
      // POST response arrives, replace the local optimistic bubble instead of
      // showing two bubbles or making the animation jump.
      final pendingIndex = messages.indexWhere((local) =>
          local['id']?.toString().startsWith('local-') == true &&
          local['status']?.toString() == 'sending' &&
          local['senderUsername']?.toString() == m['senderUsername']?.toString() &&
          local['recipientUsername']?.toString() == m['recipientUsername']?.toString() &&
          local['type']?.toString() == m['type']?.toString() &&
          local['message']?.toString() == m['message']?.toString());

      if (pendingIndex >= 0) {
        final oldId = messages[pendingIndex]['id']!.toString();
        byId.remove(oldId);
        byId[id] = m;
        changed = true;
      } else {
        byId[id] = m;
        changed = true;
      }
    }

    final merged = byId.values.toList()
      ..sort((a, b) => (DateTime.tryParse(a['createdAt']?.toString() ?? '') ?? DateTime(0))
          .compareTo(DateTime.tryParse(b['createdAt']?.toString() ?? '') ?? DateTime(0)));

    if (merged.length != messages.length) changed = true;
    messages = merged;
    return changed;
  }

  void _showBanned() {
    if (!mounted) return;
    pollTimer?.cancel();
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => BannedPage(session: widget.session)), (_) => false);
  }

  void _bottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scroll.hasClients) return;
      final target = scroll.position.maxScrollExtent;
      if (jump) {
        scroll.jumpTo(target);
      } else {
        scroll.animateTo(target, duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
      }
    });
  }

  Future<void> sendText() async {
    final text = input.text.trim();
    if (text.isEmpty) return;

    input.clear();
    final temp = <String, dynamic>{
      'id': 'local-${DateTime.now().microsecondsSinceEpoch}',
      'type': 'text',
      'message': text,
      'senderUsername': widget.session.username,
      'recipientUsername': username,
      'status': 'sending',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };

    messages = [...messages, temp];
    if (mounted) setState(() {});
    _bottom();

    try {
      final result = await api.sendMessage(widget.session.token!, username, text);
      // Reconcile the optimistic message with the canonical server message.
      // We do not remove/re-add the bubble, which keeps the send animation
      // stable even when the 1-second poll wins the race with this POST.
      _mergeMessages([result]);
      await LocalCache.saveMessages(username, messages);
      await LocalCache.markRead(username, DateTime.now().toUtc().toIso8601String());
      if (mounted) setState(() {});
      _bottom();
    } on ApiException catch (e) {
      if (e.status == 403) return _showBanned();
      final i = messages.indexWhere((m) => m['id']?.toString() == temp['id']?.toString());
      if (i >= 0) {
        messages[i] = {...messages[i], 'status': 'failed'};
        if (mounted) setState(() {});
      }
    } catch (_) {
      final i = messages.indexWhere((m) => m['id']?.toString() == temp['id']?.toString());
      if (i >= 0) {
        messages[i] = {...messages[i], 'status': 'failed'};
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> sendMedia() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF151B1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF263A33),
                  child: Icon(Icons.photo_library_outlined),
                ),
                title: const Text('Galeri'),
                subtitle: const Text('Foto atau video'),
                onTap: () => Navigator.pop(sheetContext, 'gallery'),
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF30343A),
                  child: Icon(Icons.insert_drive_file_outlined),
                ),
                title: const Text('Dokumen'),
                subtitle: const Text('File hingga 50 MB'),
                onTap: () => Navigator.pop(sheetContext, 'file'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;

    File? file;
    String fileName = '';
    String type = 'file';
    try {
      if (choice == 'gallery') {
        // pickMedia behaves like the WhatsApp gallery flow: one native
        // Android picker can return either an image or a video.
        final picked = await picker.pickMedia(
          imageQuality: 92,
          maxWidth: 2400,
          maxHeight: 2400,
        );
        if (picked == null) return;
        file = File(picked.path);
        fileName = picked.name;
        final mime = (picked.mimeType ?? '').toLowerCase();
        type = mime.startsWith('video/') ? 'video' : 'image';
        if (mime.isEmpty) {
          final lower = fileName.toLowerCase();
          type = (lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.mkv') || lower.endsWith('.webm')) ? 'video' : 'image';
        }
      } else {
        // file_picker 13.x removed the old FilePicker.platform API.
        // Use the current single-file API so analyze/build stay clean.
        final picked = await FilePicker.pickFile();
        if (picked == null || picked.path == null) return;
        file = File(picked.path!);
        fileName = picked.name;
        type = 'file';
      }

      // Every picker branch above either returns or assigns a file.
      final selectedFile = file!;
      final bytes = await selectedFile.length();
      if (bytes > 50 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File maksimal 50 MB.')),
          );
        }
        return;
      }

      if (!mounted) return;
      setState(() => sendingMedia = true);
      final result = await api.uploadMedia(
        widget.session.token!,
        username,
        selectedFile,
        type: type,
      );
      _mergeMessages([result]);
      await LocalCache.saveMessages(username, messages);
      await LocalCache.markRead(username, DateTime.now().toUtc().toIso8601String());
      if (mounted) setState(() {});
      _bottom();
    } on ApiException catch (e) {
      if (e.status == 403) {
        _showBanned();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengirim $fileName: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => sendingMedia = false);
    }
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    profileTimer?.cancel();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: const Color(0xFF10171A),
        title: Row(children: [
          CircleAvatar(radius: 19, backgroundColor: const Color(0xFF51418B), backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null, child: avatarUrl.isEmpty ? Text(displayName.isEmpty ? '?' : displayName[0].toUpperCase()) : null),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Flexible(child: Text(displayName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)), if (verified) const Padding(padding: EdgeInsets.only(left: 4), child: VerifiedBadge(size: 15))]), Text('@$username', style: const TextStyle(fontSize: 12, color: Colors.white54))])),
        ]),
        actions: [PopupMenuButton<String>(onSelected: (v) { if (v == 'rename') _rename(); }, itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Ganti nama kontak'))])],
      ),
      body: Stack(children: [
        // This layer is intentionally outside the keyboard-resized content.
        // The wallpaper therefore stays visually locked to the screen when
        // the Android keyboard opens.
        Positioned.fill(
          child: Image.asset(
            'assets/chat_background.jpg',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            filterQuality: FilterQuality.low,
          ),
        ),
        Positioned.fill(child: Container(color: const Color(0xB9080D10))),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(bottom: 76 + keyboardInset),
            child: ListView.builder(
              controller: scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
              itemCount: messages.length,
              itemBuilder: (_, i) {
                final current = messages[i];
                final previous = i > 0 ? messages[i - 1] : null;
                final currentDay = _dayKey(current['createdAt']);
                final previousDay = previous == null ? null : _dayKey(previous['createdAt']);
                return Column(
                  children: [
                    if (currentDay != previousDay) _dayChip(current['createdAt']),
                    _bubble(current),
                  ],
                );
              },
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: keyboardInset,
          child: SafeArea(bottom: true, top: false, child: _composer()),
        ),
      ]),
    );
  }

  Widget _dayChip(dynamic value) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: const Color(0xFF1E292D), borderRadius: BorderRadius.circular(12)), child: Text(_dayLabel(value), style: const TextStyle(fontSize: 12, color: Colors.white70))));

  String _dayKey(dynamic value) {
    final d = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    return d == null ? '' : '${d.year}-${d.month}-${d.day}';
  }

  String _dayLabel(dynamic value) {
    final d = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (d == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Hari Ini';
    if (diff == 1) return 'Kemarin';
    const months = ['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _bubble(Map<String, dynamic> message) {
    final me = (message['senderUsername'] ?? message['sender']) == widget.session.username;
    final type = message['type'] ?? 'text';
    final status = message['status']?.toString() ?? 'sent';
    Widget body;
    if (type == 'image' || type == 'video') {
      final url = message['url']?.toString() ?? message['mediaUrl']?.toString() ?? '';
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (url.isNotEmpty) Container(width: 230, height: 160, clipBehavior: Clip.antiAlias, decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)), child: type == 'image' ? Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image))) : Stack(fit: StackFit.expand, children: [Container(color: Colors.black45), const Center(child: Icon(Icons.play_circle_fill, size: 54, color: Colors.white))])),
        Row(mainAxisSize: MainAxisSize.min, children: [Text(type == 'video' ? 'Video' : 'Foto', style: const TextStyle(fontSize: 12)), IconButton(onPressed: () => _download(url, type), icon: const Icon(Icons.download, size: 18))]),
      ]);
    } else if (type == 'file') {
      final url = message['url']?.toString() ?? message['mediaUrl']?.toString() ?? '';
      final name = (message['fileName'] ?? message['name'] ?? message['message'] ?? 'File').toString();
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.insert_drive_file_outlined, size: 34),
        const SizedBox(width: 9),
        Flexible(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (url.isNotEmpty) IconButton(onPressed: () => _downloadFilePlaceholder(url), icon: const Icon(Icons.download, size: 18)),
      ]);
    } else {
      body = Text(message['message']?.toString() ?? '', style: const TextStyle(fontSize: 15));
    }
    final maxBubbleWidth = MediaQuery.sizeOf(context).width * .82;
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      key: ValueKey(message['id']?.toString() ?? '${message['createdAt']}-${message['message']}'),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxBubbleWidth),
        child: Container(
          margin: const EdgeInsets.only(bottom: 5),
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
          decoration: BoxDecoration(
            color: me ? const Color(0xFF2A6B55) : const Color(0xFF20282C),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // widthFactor: 1 keeps short messages compact while the
              // ConstrainedBox still limits long messages and wraps them.
              Align(
                alignment: Alignment.centerLeft,
                widthFactor: 1,
                child: body,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_time(message['createdAt']), style: const TextStyle(fontSize: 10, color: Colors.white54)),
                  if (me) ...[const SizedBox(width: 3), _ticks(status)],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ticks(String status) {
    Widget icon;
    if (status == 'failed') {
      icon = const Icon(Icons.close, color: Colors.redAccent, size: 15);
    } else if (status == 'read') {
      icon = const Icon(Icons.done_all, color: Color(0xFF53BDEB), size: 15);
    } else if (status == 'sent' || status == 'delivered') {
      icon = const Icon(Icons.done_all, color: Colors.white54, size: 15);
    } else if (status == 'sending') {
      icon = const SizedBox(width: 15, height: 15, child: Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 1.6)));
    } else {
      icon = const Icon(Icons.check, color: Colors.white54, size: 15);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: ScaleTransition(scale: animation, child: child)),
      child: KeyedSubtree(key: ValueKey(status), child: icon),
    );
  }

  String _time(dynamic value) {
    final d = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Widget _composer() => Container(
    padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
    color: const Color(0xFF10171A),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          padding: const EdgeInsets.all(10),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: sendingMedia ? null : sendMedia,
          icon: const Icon(Icons.attach_file),
        ),
        Expanded(
          child: TextField(
            controller: input,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: 'Pesan',
              filled: true,
              fillColor: const Color(0xFF20282C),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: 5),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: CircleAvatar(
            backgroundColor: const Color(0xFF6C4DFF),
            child: IconButton(
              onPressed: sendText,
              icon: const Icon(Icons.send, color: Colors.white, size: 20),
            ),
          ),
        ),
      ],
    ),
  );

  void _downloadFilePlaceholder(String url) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File sudah dikirim. Download file bisa ditambahkan saat endpoint download server tersedia.')),
    );
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: displayName);
    final value = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('Ganti nama kontak'), content: TextField(controller: controller, autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Simpan'))]));
    controller.dispose();
    if (value != null && value.isNotEmpty) {
      try {
        await api.renameContact(widget.session.token!, username, value);
        if (mounted) {
          setState(() => displayName = value);
        }
      } on ApiException catch (e) {
        if (e.status == 403) {
          _showBanned();
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message)),
          );
        }
      }
    }
  }

  Future<bool> _requestGalleryPermission({required bool video}) async {
    // Android 13+ uses separate media permissions. The permission is only
    // requested when saving media; picking media uses the system Photo Picker.
    if (!Platform.isAndroid) return true;

    final permission = video ? Permission.videos : Permission.photos;
    final status = await permission.request();
    return status.isGranted || status.isLimited;
  }

  Future<void> _download(String url, dynamic type) async {
    if (url.isEmpty) return;
    try {
      final isVideo = type == 'video';
      final allowed = await _requestGalleryPermission(video: isVideo);
      if (!allowed) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Izin galeri diperlukan untuk menyimpan media.')),
          );
        }
        return;
      }

      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        throw Exception('URL media tidak valid');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      if (!isVideo) {
        final response = await http.get(uri);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('Server mengembalikan HTTP ${response.statusCode}');
        }

        final contentType = response.headers['content-type'] ?? '';
        final extension = contentType.contains('png') ? 'png'
            : contentType.contains('webp') ? 'webp'
            : contentType.contains('gif') ? 'gif'
            : 'jpg';
        final result = await SaverGallery.saveImage(
          Uint8List.fromList(response.bodyBytes),
          fileName: 'ChatWithU_$timestamp.$extension',
          androidRelativePath: 'Pictures/ChatWithU',
          skipIfExists: false,
        );

        if (!result.isSuccess) {
          throw Exception(result.errorMessage ?? 'Gagal menyimpan gambar');
        }
      } else {
        final client = http.Client();
        try {
          final request = http.Request('GET', uri);
          final response = await client.send(request);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw Exception('Server mengembalikan HTTP ${response.statusCode}');
          }

          final tempDir = await Directory.systemTemp.createTemp('chatwithu_');
          final tempFile = File('${tempDir.path}/ChatWithU_$timestamp.mp4');
          final sink = tempFile.openWrite();
          await response.stream.pipe(sink);

          try {
            final result = await SaverGallery.saveFile(
              filePath: tempFile.path,
              fileName: 'ChatWithU_$timestamp.mp4',
              androidRelativePath: 'Movies/ChatWithU',
              skipIfExists: false,
            );
            if (!result.isSuccess) {
              throw Exception(result.errorMessage ?? 'Gagal menyimpan video');
            }
          } finally {
            try {
              await tempFile.delete();
            } catch (_) {}
            try {
              await tempDir.delete();
            } catch (_) {}
          }
        } finally {
          client.close();
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Media disimpan ke galeri.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan: $e')),
        );
      }
    }
  }
}
