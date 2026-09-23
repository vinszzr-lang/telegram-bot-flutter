import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:saver_gallery/saver_gallery.dart';
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
import 'banned_page.dart';
import 'contact_profile_page.dart';

class ChatPage extends StatefulWidget {
  final Session session;
  final Map<String, dynamic> contact;
  const ChatPage({super.key, required this.session, required this.contact});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with SingleTickerProviderStateMixin {
  late String username;
  late String contactName;
  String avatarUrl = '';
  bool verified = false;
  final api = Api();
  final input = TextEditingController();
  final scroll = ScrollController();
  final picker = ImagePicker();
  final socket = SocketService();
  Timer? pollTimer;
  Timer? typingStopTimer;
  bool syncing = false;
  bool sendingMedia = false;
  bool remoteTyping = false;
  List<Map<String, dynamic>> messages = [];
  String? lastCursor;
  String? wallpaperPath;
  final Map<String, String> _downloadedMediaPaths = {};
  final Set<String> _downloadingMedia = <String>{};
  final List<String> _stickers = <String>[];
  bool _showStickerTray = false;
  final Set<String> _selectedIds = <String>{};
  final Map<String, double> _swipeOffsets = <String, double>{};
  Map<String,dynamic>? _replyingTo;
  bool get _isSavedContact => widget.contact['saved'] == true;

  @override
  void initState() {
    super.initState();
    username = widget.contact['username'].toString();
    // IMPORTANT: this is the saved contact name. Never overwrite it with the
    // profile's first/last name during profile refresh.
    contactName = (widget.contact['name'] ?? widget.contact['displayName'] ?? username).toString();
    avatarUrl = (widget.contact['avatarUrl'] ?? '').toString();
    verified = widget.contact['verified'] == true;
    input.addListener(_onInputChanged);
    _loadStickers();
    _connectSocket();
    load();
    pollTimer = Timer.periodic(const Duration(seconds: 8), (_) { if (!socket.connected) { syncMessages().whenComplete(() { if (mounted && widget.session.token != null && !socket.connected) { _connectSocket(); } }); } });
  }

  void _connectSocket() {
    if (widget.session.token == null) return;
    socket.connect(Api.baseUrl, widget.session.token!);
    socket.on('message:new', _onSocketMessage);
    socket.on('typing', _onTyping);
    socket.on('message:read', _onRead);
    socket.on('message:updated', _onMessageUpdated);
    socket.on('profile:updated', _onProfileUpdated);
  }

  void _onSocketMessage(dynamic raw) {
    if (raw is! Map) return;
    final m = Map<String, dynamic>.from(raw);
    final sender = m['senderUsername']?.toString();
    final recipient = m['recipientUsername']?.toString();
    if (sender != username && recipient != username) return;
    _mergeMessages([m]);
    LocalCache.saveMessages(username, messages);
    if (m['type']?.toString() == 'sticker' && m['senderUsername']?.toString() != widget.session.username) {
      _downloadStickerToCache(m);
    }
    if (sender == username) remoteTyping = false;
    if (mounted) setState(() {});
    if (sender == username || recipient == widget.session.username) _bottom();
  }

  void _onTyping(dynamic raw) {
    if (raw is! Map) return;
    final from = raw['from']?.toString();
    // Typing is always displayed to the other participant only.
    // Ignore any socket echo/loopback from this device.
    if (from == null || from.isEmpty || from == widget.session.username) return;
    if (from != username) return;
    final value = raw['typing'] == true;
    if (mounted && remoteTyping != value) setState(() => remoteTyping = value);
  }

  void _onRead(dynamic raw) {
    if (raw is! Map || raw['username']?.toString() != username) return;
    final ids = (raw['ids'] is List)
        ? (raw['ids'] as List).map((e) => e.toString()).where((e) => e.isNotEmpty).toSet()
        : <String>{};
    // A read event must identify the exact messages that were opened.
    // Never mark every outgoing message read just because a generic event arrived.
    if (ids.isEmpty) return;
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final id = messages[i]['id']?.toString();
      if (id != null && ids.contains(id) && messages[i]['senderUsername']?.toString() == widget.session.username && messages[i]['status'] != 'read') {
        messages[i] = {...messages[i], 'status': 'read'};
        changed = true;
      }
    }
    if (changed) {
      LocalCache.saveMessages(username, messages);
      if (mounted) setState(() {});
    }
  }

  void _onMessageUpdated(dynamic raw) {
    if (raw is! Map) return;
    final m = Map<String,dynamic>.from(raw);
    final id = m['id']?.toString();
    if (id == null) return;
    _mergeMessages([m]);
    LocalCache.saveMessages(username, messages);
    if (mounted) setState(() {});
  }

  void _onProfileUpdated(dynamic raw) {
    if (raw is! Map) return;
    final u = raw['user'];
    if (u is! Map || u['username']?.toString() != username) return;
    if (!mounted) return;
    setState(() {
      verified = u['verified'] == true;
      avatarUrl = (u['avatarUrl'] ?? avatarUrl).toString();
    });
  }

  Future<void> load() async {
    wallpaperPath = await LocalCache.wallpaper(username);
    final local = await LocalCache.messages(username);
    if (mounted && local.isNotEmpty) setState(() => messages = local);
    await syncMessages(full: true);
    await _restoreLocalMedia();
    for (final m in List<Map<String, dynamic>>.from(messages)) {
      if (m['type']?.toString() == 'sticker' && m['senderUsername']?.toString() != widget.session.username && !_downloadedMediaPaths.containsKey(m['id']?.toString())) {
        await _downloadStickerToCache(m);
      }
    }
    await _markRead();
    _bottom(jump: true);
  }

  Future<void> _markRead() async {
    final token = widget.session.token;
    if (token == null) return;
    final latest = messages.isEmpty ? DateTime.now().toUtc() : _newestDate() ?? DateTime.now().toUtc();
    await LocalCache.markRead(username, latest.toUtc().toIso8601String());
    try {
      // The HTTP endpoint is authoritative and returns/ broadcasts the exact
      // message IDs that were actually read. Do not emit a generic read event
      // from the reader, because that can incorrectly turn sent messages blue.
      await api.markRead(token, username);
    } catch (_) {}
  }

  DateTime? _newestDate() {
    DateTime? newest;
    for (final m in messages) {
      final d = DateTime.tryParse(m['createdAt']?.toString() ?? '');
      if (d != null && (newest == null || d.isAfter(newest))) newest = d;
    }
    return newest;
  }

  Future<void> syncMessages({bool full = false}) async {
    if (syncing || widget.session.token == null) return;
    syncing = true;
    try {
      final remote = await api.messages(widget.session.token!, username, since: full ? null : lastCursor);
      final changed = _mergeMessages(remote.map((e) => Map<String, dynamic>.from(e)).toList());
      final newest = _newestDate();
      if (newest != null) lastCursor = newest.toUtc().toIso8601String();
      await LocalCache.saveMessages(username, messages);
      if (changed && mounted) {
        setState(() {});
        _bottom();
      }
      await _markRead();
    } on ApiException catch (e) {
      if (e.status == 403) _showBanned();
    } catch (_) {}
    finally { syncing = false; }
  }

  bool _mergeMessages(List<Map<String, dynamic>> incoming) {
    if (incoming.isEmpty) return false;
    final byId = <String, Map<String, dynamic>>{};
    for (final m in messages) { final id = m['id']?.toString(); if (id != null) byId[id] = m; }
    var changed = false;
    for (final raw in incoming) {
      final m = Map<String, dynamic>.from(raw);
      final id = m['id']?.toString();
      if (id == null || id.isEmpty) continue;
      if (byId.containsKey(id)) { byId[id] = {...byId[id]!, ...m}; changed = true; continue; }
      final pendingIndex = messages.indexWhere((local) =>
        local['id']?.toString().startsWith('local-') == true &&
        local['status']?.toString() == 'sending' &&
        local['senderUsername']?.toString() == m['senderUsername']?.toString() &&
        local['recipientUsername']?.toString() == m['recipientUsername']?.toString() &&
        local['type']?.toString() == m['type']?.toString() &&
        local['message']?.toString() == m['message']?.toString());
      if (pendingIndex >= 0) byId.remove(messages[pendingIndex]['id']?.toString());
      byId[id] = m; changed = true;
    }
    final merged = byId.values.toList()..sort((a,b) => (DateTime.tryParse(a['createdAt']?.toString() ?? '') ?? DateTime(0)).compareTo(DateTime.tryParse(b['createdAt']?.toString() ?? '') ?? DateTime(0)));
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
        scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onInputChanged() {
    final hasText = input.text.trim().isNotEmpty;
    if (!hasText) {
      typingStopTimer?.cancel();
      socket.emit('typing:stop', {'to': username});
      return;
    }
    socket.emit('typing:start', {'to': username});
    typingStopTimer?.cancel();
    typingStopTimer = Timer(const Duration(milliseconds: 1200), () => socket.emit('typing:stop', {'to': username}));
  }

  Future<void> sendText() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    input.clear();
    typingStopTimer?.cancel();
    socket.emit('typing:stop', {'to': username});
    if (mounted) setState(() => remoteTyping = false);
    final replyId = _replyingTo?['id']?.toString();
    final oldReply = _replyingTo;
    setState(() => _replyingTo = null);
    try {
      // No optimistic local row: the server socket echo and HTTP response use
      // the same message id, so the merge layer can never show it twice.
      final clientMessageId = 'chat-${DateTime.now().microsecondsSinceEpoch}-${text.hashCode.abs()}';
      final result = await api.sendMessage(widget.session.token!, username, text, replyToId: replyId, clientMessageId: clientMessageId);
      _mergeMessages([result]);
      await LocalCache.saveMessages(username, messages);
      if (mounted) setState(() {}); _bottom();
    } on ApiException catch (e) {
      if (e.status == 403) return _showBanned();
      if (mounted) { setState(() => _replyingTo = oldReply); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message))); }
    } catch (e) {
      if (mounted) { setState(() => _replyingTo = oldReply); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengirim: $e'))); }
    }
  }

  Future<void> _sendPickedMedia(XFile picked, {required String type}) async {
    final file = File(picked.path);
    final fileName = picked.name;
    try {
      final size = await file.length();
      if (size <= 0) throw Exception('Foto/video tidak dapat dibaca.');
      if (size > 50 * 1024 * 1024) throw Exception('File maksimal 50 MB.');

      String? caption;
      if (type == 'image' || type == 'video') {
        final composed = await _composeMedia(file, type: type);
        if (composed == null) return;
        caption = composed.caption;
      }

      if (!mounted) return;
      setState(() => sendingMedia = true);
      final result = await api.uploadMedia(
        widget.session.token!,
        username,
        file,
        type: type,
        caption: caption,
        replyToId: _replyingTo?['id']?.toString(),
         clientMessageId: 'media-${DateTime.now().microsecondsSinceEpoch}-${fileName.hashCode.abs()}',
      );
      _mergeMessages([result]);
      _replyingTo = null;
      // Keep the sender's own copy on-device. The server copy is only a relay
      // and may be deleted as soon as the recipient successfully downloads it.
      final local = await _localMediaFile(Map<String,dynamic>.from(result));
      await local.parent.create(recursive: true);
      await file.copy(local.path);
      _downloadedMediaPaths[result['id'].toString()] = local.path;
      await LocalCache.saveMessages(username, messages);
      if (mounted) setState(() {});
      _bottom();
    } on ApiException catch (e) {
      if (e.status == 403) {
        _showBanned();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengirim $fileName: $e')));
    } finally {
      if (mounted) setState(() => sendingMedia = false);
    }
  }

  Future<_MediaComposeResult?> _composeMedia(File file, {required String type}) async {
    if (!await file.exists() || !mounted) return null;
    return Navigator.of(context).push<_MediaComposeResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _MediaComposerPage(
          file: file,
          type: type,
          recipientName: contactName,
        ),
      ),
    );
  }

  Future<Directory> _stickerDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final safeUser = (widget.session.username ?? 'unknown').replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final out = Directory('${dir.path}/chatwithu_stickers/$safeUser');
    await out.create(recursive: true);
    return out;
  }

  Future<void> _loadStickers() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'chatwithu_stickers_${widget.session.username}';
    final values = prefs.getStringList(key) ?? <String>[];
    final valid = <String>[];
    for (final path in values) {
      if (await File(path).exists()) valid.add(path);
    }
    if (mounted) setState(() => _stickers..clear()..addAll(valid));
    if (valid.length != values.length) await prefs.setStringList(key, valid);
  }

  Future<void> _saveStickerPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'chatwithu_stickers_${widget.session.username}';
    final values = [...(prefs.getStringList(key) ?? <String>[])];
    if (!values.contains(path)) values.add(path);
    await prefs.setStringList(key, values);
    if (mounted) setState(() => _stickers..clear()..addAll(values));
  }

  Future<ui.Image> _decodeStickerImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 768);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Future<String?> _createStickerPng({String? text, Color background = const Color(0xFF7B61FF), File? photo}) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      Size canvasSize = const Size(512, 512);
      ui.Image? sourceImage;
      if (photo != null) {
        sourceImage = await _decodeStickerImage(await photo.readAsBytes());
        final ratio = sourceImage.width / sourceImage.height;
        if (ratio >= 1) {
          canvasSize = Size(768, math.max(240, 768 / ratio));
        } else {
          canvasSize = Size(math.max(240, 768 * ratio), 768);
        }
      }
      final bounds = Offset.zero & canvasSize;
      if (sourceImage != null) {
        final src = Rect.fromLTWH(0, 0, sourceImage.width.toDouble(), sourceImage.height.toDouble());
        final scale = math.min(canvasSize.width / sourceImage.width, canvasSize.height / sourceImage.height);
        final w = sourceImage.width * scale;
        final h = sourceImage.height * scale;
        final dst = Rect.fromLTWH((canvasSize.width - w) / 2, (canvasSize.height - h) / 2, w, h);
        canvas.drawColor(Colors.transparent, BlendMode.clear);
        canvas.drawImageRect(sourceImage, src, dst, Paint()..filterQuality = FilterQuality.high);
      } else {
        final bg = Paint()..color = background;
        canvas.drawRRect(RRect.fromRectAndRadius(bounds, const Radius.circular(64)), bg);
        final painter = TextPainter(
          text: TextSpan(text: text ?? 'X Chat', style: const TextStyle(color: Colors.white, fontSize: 62, fontWeight: FontWeight.w800, height: 1.05)),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          maxLines: 4,
        )..layout(maxWidth: canvasSize.width - 70);
        painter.paint(canvas, Offset((canvasSize.width - painter.width) / 2, (canvasSize.height - painter.height) / 2));
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(canvasSize.width.round(), canvasSize.height.round());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      final dir = await _stickerDirectory();
      final file = File('${dir.path}/sticker_${DateTime.now().microsecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      await _saveStickerPath(file.path);
      return file.path;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal membuat sticker: $e')));
      return null;
    }
  }

  Future<void> _createSticker() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF10171A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (sheet) => _StickerMakerSheet(picker: picker),
    );
    if (result == null) return;
    final color = result['color'] as Color? ?? const Color(0xFF7B61FF);
    final photo = result['photo'] as XFile?;
    final text = (result['text'] ?? '').toString().trim();
    if (photo == null && text.isEmpty) return;
    final path = await _createStickerPng(text: text, background: color, photo: photo == null ? null : File(photo.path));
    if (path != null && mounted) setState(() => _showStickerTray = true);
  }

  Future<void> _sendSticker(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      if (!mounted) return;
      setState(() => sendingMedia = true);
      final result = await api.uploadMedia(widget.session.token!, username, file, type: 'sticker', replyToId: _replyingTo?['id']?.toString(), clientMessageId: 'sticker-${DateTime.now().microsecondsSinceEpoch}-${path.hashCode.abs()}');
      _mergeMessages([result]);
      _replyingTo = null;
      final local = await _localMediaFile(Map<String, dynamic>.from(result));
      await local.parent.create(recursive: true);
      await file.copy(local.path);
      _downloadedMediaPaths[result['id'].toString()] = local.path;
      await LocalCache.saveMessages(username, messages);
      if (mounted) setState(() {});
      _bottom();
    } on ApiException catch (e) {
      if (e.status == 403) {
        _showBanned();
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengirim sticker: $e')));
    } finally {
      if (mounted) setState(() => sendingMedia = false);
    }
  }

  Future<void> _favoriteIncomingSticker(Map<String, dynamic> message) async {
    final local = _downloadedMediaPaths[message['id']?.toString()];
    if (local == null || !await File(local).exists()) return;
    await _saveStickerPath(local);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sticker ditambahkan ke favorit')));
  }

  Future<void> _downloadStickerToCache(Map<String, dynamic> message) async {
    final id = message['id']?.toString() ?? '';
    if (id.isEmpty || _downloadedMediaPaths.containsKey(id) || widget.session.token == null) return;
    try {
      final res = await api.downloadMedia(widget.session.token!, id);
      if (res.statusCode != 200) return;
      final local = await _localMediaFile(message);
      await local.parent.create(recursive: true);
      await local.writeAsBytes(res.bodyBytes, flush: true);
      _downloadedMediaPaths[id] = local.path;
      await LocalCache.saveMessages(username, messages);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _pickPhoto() async {
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 2400, maxHeight: 2400);
    if (picked != null) await _sendPickedMedia(picked, type: 'image');
  }

  Future<void> _takePhoto() async {
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 92, maxWidth: 2400, maxHeight: 2400);
    if (picked != null) await _sendPickedMedia(picked, type: 'image');
  }

  Future<void> _pickVideo() async {
    final picked = await picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 10));
    if (picked != null) await _sendPickedMedia(picked, type: 'video');
  }

  Future<void> _pickDocument() async {
    final picked = await FilePicker.pickFile();
    if (picked == null || picked.path == null) return;
    await _sendPickedMedia(XFile(picked.path!, name: picked.name), type: 'file');
  }

  Future<void> sendMedia() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF10171A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10))),
            const SizedBox(height: 14),
            const Align(alignment: Alignment.centerLeft, child: Text('Kirim lampiran', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _AttachmentChoice(icon: Icons.photo_rounded, label: 'Foto', color: const Color(0xFF6C4DFF), onTap: () => Navigator.pop(sheetContext, 'photo'))),
              const SizedBox(width: 10),
              Expanded(child: _AttachmentChoice(icon: Icons.videocam_rounded, label: 'Video', color: const Color(0xFFE05B8D), onTap: () => Navigator.pop(sheetContext, 'video'))),
              const SizedBox(width: 10),
              Expanded(child: _AttachmentChoice(icon: Icons.camera_alt_rounded, label: 'Kamera', color: const Color(0xFF20C76B), onTap: () => Navigator.pop(sheetContext, 'camera'))),
              const SizedBox(width: 10),
              Expanded(child: _AttachmentChoice(icon: Icons.description_rounded, label: 'File', color: const Color(0xFF3EA6FF), onTap: () => Navigator.pop(sheetContext, 'file'))),
            ]),
          ]),
        ),
      ),
    );
    if (choice == 'photo') return _pickPhoto();
    if (choice == 'video') return _pickVideo();
    if (choice == 'camera') return _takePhoto();
    if (choice == 'file') return _pickDocument();
  }

  Future<void> _addUnknownContact() async {
    final c = TextEditingController(text: contactName);
    final value = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('Tambah kontak'), content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Nama kontak')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Simpan'))]));
    c.dispose();
    if (value == null || value.isEmpty) return;
    try { await api.addContact(widget.session.token!, username, value); widget.contact['saved'] = true; widget.contact['name'] = value; if (mounted) setState(() => contactName = value); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
  }

  Future<void> _blockUnknown() async {
    try { await api.blockUser(widget.session.token!, username); if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kontak diblokir'))); Navigator.pop(context, true); } } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
  }

  void _startReply(Map<String,dynamic> m) { setState(() => _replyingTo = m); }
  void _toggleSelect(Map<String,dynamic> m) { final id=m['id']?.toString(); if (id == null) return; setState(() { if (_selectedIds.contains(id)) { _selectedIds.remove(id); } else { _selectedIds.add(id); } }); }
  void _longSelect(Map<String,dynamic> m) { if(_selectedIds.isEmpty){_hapticLongPress();final id=m['id']?.toString();if(id!=null)setState(()=>_selectedIds.add(id));}else{_toggleSelect(m);} }
  void _hapticLongPress() { const MethodChannel('xchat/notifications').invokeMethod('vibrate500').catchError((_) => null); }
  Future<void> _copySelected() async { final texts=messages.where((m)=>_selectedIds.contains(m['id']?.toString())&&m['type']=='text'&&m['deleted']!=true).map((m)=>m['message']?.toString()??'').where((x)=>x.isNotEmpty).toList(); if(texts.isEmpty)return; await Clipboard.setData(ClipboardData(text:texts.join('\n'))); if(mounted){setState(()=>_selectedIds.clear());ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Pesan disalin')));} }
  Future<void> _deleteSelected() async { final ids=_selectedIds.toList(); for(final id in ids){final m=messages.firstWhere((x)=>x['id']?.toString()==id,orElse:()=>{});if(m.isEmpty||m['senderUsername']?.toString()!=widget.session.username)continue;try{await api.deleteChatMessage(widget.session.token!,username,id);}catch(_){}} _selectedIds.clear(); await syncMessages(full:true); if(mounted)setState((){}); }
  Widget _quotedMessage(Map<String,dynamic>? m){if(m==null)return const SizedBox.shrink();final type=m['type']?.toString()??'text';final text=type=='text'?(m['message']??'').toString():type=='image'?'Foto':type=='video'?'Video':type=='sticker'?'Sticker':type=='file'?'File':'Pesan';final sender=m['senderUsername']?.toString()==widget.session.username?'Anda':contactName;return Container(width:double.infinity,margin:const EdgeInsets.only(bottom:6),padding:const EdgeInsets.fromLTRB(9,6,8,6),decoration:BoxDecoration(color:Colors.black.withValues(alpha: .16),borderRadius:BorderRadius.circular(8),border:const Border(left:BorderSide(color:Color(0xFF58D68D),width:3))),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(sender,style:const TextStyle(color:Color(0xFF62D696),fontWeight:FontWeight.w800,fontSize:12)),Text(text,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white70,fontSize:12))]));}

  Future<void> _rename() async {
    if (!_isSavedContact) { await _addUnknownContact(); return; }
    final c=TextEditingController(text:contactName);
    final value=await showDialog<String>(context:context,builder:(_)=>AlertDialog(title:const Text('Ganti nama kontak'),content:TextField(controller:c,autofocus:true,decoration:const InputDecoration(hintText:'Nama kontak')),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Batal')),FilledButton(onPressed:()=>Navigator.pop(context,c.text.trim()),child:const Text('Simpan'))]));
    c.dispose(); if(value==null||value.isEmpty)return;
    try{await api.renameContact(widget.session.token!,username,value);if(mounted)setState(()=>contactName=value);widget.contact['name']=value;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
  }

  Future<void> _clearChat() async {
    final ok=await showDialog<bool>(context:context,builder:(_)=>AlertDialog(title:const Text('Bersihkan chat?'),content:const Text('Riwayat akan dihapus dari tampilan kamu saja. Chat dan kontak tetap ada.'),actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Batal')),FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Bersihkan'))]))??false;
    if(!ok)return;
    try{await api.clearChat(widget.session.token!,username);await LocalCache.clearLocalMessages(username);if(mounted)setState(()=>messages=[]);lastCursor=null;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}
  }

  Future<void> _searchChat() async {
    await showSearch(context:context,delegate:_ChatSearchDelegate(api:api,token:widget.session.token!,username:username,localMessages:messages));
  }

  Future<void> _theme() async {
    final choice=await showModalBottomSheet<String>(context:context,backgroundColor:const Color(0xFF151B1E),builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[
      const ListTile(title:Text('Tema obrolan'),subtitle:Text('Pilih wallpaper untuk chat ini')),
      ListTile(leading:const Icon(Icons.wallpaper),title:const Text('Wallpaper default'),onTap:()=>Navigator.pop(c,'default')),
      ListTile(leading:const Icon(Icons.photo_library_outlined),title:const Text('Dari galeri'),onTap:()=>Navigator.pop(c,'gallery')),
      const SizedBox(height:8),
    ])));
    if(choice==null)return;
    if(choice=='default'){await LocalCache.setWallpaper(username,'');if(mounted)setState(()=>wallpaperPath=null);return;}
    final picked=await picker.pickImage(source:ImageSource.gallery,imageQuality:88,maxWidth:2200,maxHeight:2200);if(picked==null)return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final oldPath = await LocalCache.wallpaper(username);
      if (oldPath != null && oldPath.isNotEmpty) {
        final old = File(oldPath);
        if (await old.exists()) { try { await old.delete(); } catch (_) {} }
      }
      // Use a unique filename every time. Reusing wallpaper_$username.jpg can
      // make Flutter's image cache show the previous wallpaper after switching.
      final extMatch = RegExp(r'\.(jpg|jpeg|png|webp|heic|heif)$', caseSensitive: false).firstMatch(picked.name);
      final ext = extMatch == null ? 'jpg' : extMatch.group(1)!.toLowerCase();
      final dest = File('${dir.path}/wallpaper_${username}_${DateTime.now().microsecondsSinceEpoch}.$ext');
      await File(picked.path).copy(dest.path);
      await LocalCache.setWallpaper(username, dest.path);
      if (mounted) setState(() => wallpaperPath = dest.path);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal memasang wallpaper: $e')));
    }
  }

  @override
  void dispose(){pollTimer?.cancel();typingStopTimer?.cancel();socket.emit('typing:stop',{'to':username});socket.disconnect();input.removeListener(_onInputChanged);input.dispose();scroll.dispose();super.dispose();}

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: const Color(0xFF080D10),
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: const Color(0xFF10171A),
        title: _selectedIds.isNotEmpty ? Text('${_selectedIds.length} dipilih', style: const TextStyle(fontSize:18,fontWeight:FontWeight.w800)) : InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ContactProfilePage(session: widget.session, user: widget.contact))),
          child: Row(
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: const Color(0xFF51418B),
              backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
              child: avatarUrl.isEmpty ? Text(contactName.isEmpty ? '?' : contactName[0].toUpperCase()) : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(contactName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                      if (verified) const Padding(padding: EdgeInsets.only(left: 4), child: VerifiedBadge(size: 15)),
                    ],
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: remoteTyping
                        ? const _TypingText(key: ValueKey('typing'))
                        : Text('@$username', key: const ValueKey('username'), style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
        actions: _selectedIds.isNotEmpty ? [
          if (messages.any((m)=>_selectedIds.contains(m['id']?.toString())&&m['type']=='text')) IconButton(onPressed:_copySelected,icon:const Icon(Icons.copy_outlined)),
          IconButton(onPressed:_deleteSelected,icon:const Icon(Icons.delete_outline)),
          IconButton(onPressed:()=>setState(()=>_selectedIds.clear()),icon:const Icon(Icons.close)),
        ] : [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'rename': _rename(); break;
                case 'media': Navigator.push(context, MaterialPageRoute(builder: (_) => ChatMediaPage(session: widget.session, username: username, contactName: contactName))); break;
                case 'clear': _clearChat(); break;
                case 'search': _searchChat(); break;
                case 'theme': _theme(); break;
                case 'add': _addUnknownContact(); break;
                case 'block': _blockUnknown(); break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'search', child: Text('Cari')),
              const PopupMenuItem(value: 'media', child: Text('Media, tautan, dan dok')),
              if (_isSavedContact) const PopupMenuItem(value: 'rename', child: Text('Ganti nama kontak')),
              if (!_isSavedContact) const PopupMenuItem(value: 'add', child: Text('Tambah kontak')),
              if (!_isSavedContact) const PopupMenuItem(value: 'block', child: Text('Blokir')),
              const PopupMenuItem(value: 'clear', child: Text('Bersihkan chat')),
              const PopupMenuItem(value: 'theme', child: Text('Tema obrolan')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        if (!_isSavedContact) Container(color: const Color(0xFF182329), padding: const EdgeInsets.fromLTRB(12, 8, 8, 8), child: Row(children: [const Expanded(child: Text('Anda belum menyimpan kontak ini', style: TextStyle(color: Colors.white70, fontSize: 12))), TextButton(onPressed: _blockUnknown, child: const Text('Blokir')), FilledButton(onPressed: _addUnknownContact, child: const Text('Tambah'))])),
        Expanded(child: Stack(children: [
          Positioned.fill(child: _wallpaper()),
          Positioned.fill(child: Container(color: const Color(0xB9080D10))),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(bottom: 76 + keyboard),
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                itemCount: messages.length,
                itemBuilder: (_, i) {
                  final m = messages[i];
                  final p = i > 0 ? messages[i - 1] : null;
                  final day = _dayKey(m['createdAt']);
                  final pd = p == null ? null : _dayKey(p['createdAt']);
                  return Column(children: [if (day != pd) _dayChip(m['createdAt']), _bubble(m)]);
                },
              ),
            ),
          ),
          Positioned(left: 0, right: 0, bottom: keyboard, child: SafeArea(bottom: true, top: false, child: _composer())),
        ],)),
      ]),
    );
  }

  Widget _wallpaper(){if(wallpaperPath!=null&&wallpaperPath!.isNotEmpty&&File(wallpaperPath!).existsSync())return Image.file(File(wallpaperPath!),key:ValueKey(wallpaperPath),fit:BoxFit.cover);return Image.asset('assets/xchat_background.jpg',fit:BoxFit.cover,alignment:Alignment.topCenter,filterQuality:FilterQuality.low);}
  Widget _dayChip(dynamic v)=>Padding(padding:const EdgeInsets.symmetric(vertical:8),child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:6),decoration:BoxDecoration(color:const Color(0xFF1E292D),borderRadius:BorderRadius.circular(12)),child:Text(_dayLabel(v),style:const TextStyle(fontSize:12,color:Colors.white70))));
  String _dayKey(dynamic v){final d=DateTime.tryParse(v?.toString()??'')?.toLocal();return d==null?'':'${d.year}-${d.month}-${d.day}';}
  String _dayLabel(dynamic v){final d=DateTime.tryParse(v?.toString()??'')?.toLocal();if(d==null)return'';final n=DateTime.now();final diff=DateTime(n.year,n.month,n.day).difference(DateTime(d.year,d.month,d.day)).inDays;if(diff==0)return'Hari Ini';if(diff==1)return'Kemarin';const m=['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember'];return'${d.day} ${m[d.month-1]} ${d.year}';}

  Widget _bubble(Map<String,dynamic> message){
    final me=(message['senderUsername']??message['sender'])==widget.session.username;
    final type=message['type']??'text';
    final deleted=message['deleted']==true;
    if(deleted){
      return _interactive(message,Align(alignment:me?Alignment.centerRight:Alignment.centerLeft,child:Container(margin:const EdgeInsets.only(bottom:5),padding:const EdgeInsets.fromLTRB(12,9,12,9),decoration:BoxDecoration(color:const Color(0xFF20282C),borderRadius:BorderRadius.circular(12)),child:const Row(mainAxisSize:MainAxisSize.min,children:[Icon(Icons.block_rounded,size:15,color:Colors.white38),SizedBox(width:5),Text('Pesan ini telah dihapus',style:TextStyle(color:Colors.white38,fontStyle:FontStyle.italic))]))));
    }

    // Foto/video dibuat sebagai satu bubble yang lebarnya mengikuti frame media.
    // Caption dan waktu tetap berada di bawah media, bukan memperlebar bubble.
    if(type=='image'||type=='video'){
      final url=(message['url']??message['mediaUrl']??'').toString();
      final id=(message['id']??url).toString();
      final localPath=_downloadedMediaPaths[id];
      final downloaded=localPath!=null && File(localPath).existsSync();
      return _interactive(message, Align(
        alignment:me?Alignment.centerRight:Alignment.centerLeft,
        child:Column(crossAxisAlignment:me?CrossAxisAlignment.end:CrossAxisAlignment.start,children:[
          if(message['replyTo'] is Map) _quotedMessage(Map<String,dynamic>.from(message['replyTo'])),
          _MediaMessageBubble(
          key:ValueKey(message['id']?.toString()),
          type:type.toString(),
          url:url,
          previewUrl:(message['previewUrl']??url).toString(),
          localPath:downloaded?localPath:null,
          downloaded:downloaded,
          isMine:me,
          caption:(message['caption']?.toString()??'').trim(),
          size:_formatBytes(message['fileSize'] ?? message['size']),
          time:_time(message['createdAt']),
          status:message['status']?.toString()??'sent',
          downloading:_downloadingMedia.contains(id),
          onDownload:()=>_downloadMediaToCache(message),
          onOpenImage:()=>_openImageViewer(url,message,localPath:downloaded?localPath:null),
          onOpenVideo:downloaded?()=>_openVideoViewer(localPath,message):null,
          maxWidth:math.min(330,MediaQuery.sizeOf(context).width*.80),
          maxHeight:450,
          ),
        ]),
      ));
    }

    Widget body;
    if(type=='sticker'){
      final url=(message['url']??message['mediaUrl']??'').toString();
      final id=(message['id']??url).toString();
      final localPath=_downloadedMediaPaths[id];
      final downloaded=localPath!=null && File(localPath).existsSync();
      final size=_formatBytes(message['fileSize'] ?? message['size']);
      final image = downloaded
          ? Image.file(File(localPath),fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.broken_image)))
          : ImageFiltered(imageFilter:ui.ImageFilter.blur(sigmaX:11,sigmaY:11),child:Image.network((message['previewUrl']??url).toString(),fit:BoxFit.cover,errorBuilder:(_,__,___)=>Container(color:Colors.black54,child:const Center(child:Icon(Icons.image_outlined,color:Colors.white54,size:42)))));
      body=GestureDetector(
        onLongPress:!me&&downloaded?()=>_favoriteIncomingSticker(message):null,
        onTap:downloaded?()=>_showStickerActions(message):null,
        child:Stack(alignment:Alignment.center,children:[
          ConstrainedBox(constraints:const BoxConstraints(maxWidth:190,maxHeight:190),child:ClipRRect(borderRadius:BorderRadius.circular(18),child:image)),
          if(!me&&!downloaded)_mediaDownloadButton(message,size),
        ]),
      );
    }else if(type=='file'){
      final url=(message['url']??message['mediaUrl']??'').toString();
      final name=(message['fileName']??message['name']??message['message']??'File').toString();
      body=Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.insert_drive_file_outlined,size:34),const SizedBox(width:9),Flexible(child:Text(name,maxLines:2,overflow:TextOverflow.ellipsis)),if(url.isNotEmpty)IconButton(onPressed:()=>_downloadFilePlaceholder(url),icon:const Icon(Icons.download,size:18))]);
    }else{
      body=Text(message['message']?.toString()??'',style:const TextStyle(fontSize:15));
    }

    final max=MediaQuery.sizeOf(context).width*.82;
    final status=message['status']?.toString()??'sent';
    return _interactive(message, Align(
      alignment:me?Alignment.centerRight:Alignment.centerLeft,
      child:ConstrainedBox(
        key:ValueKey(message['id']?.toString()),
        constraints:BoxConstraints(maxWidth:max),
        child:Container(
          margin:const EdgeInsets.only(bottom:5),
          padding:const EdgeInsets.fromLTRB(12,8,8,6),
          decoration:BoxDecoration(color:me?const Color(0xFF2A6B55):const Color(0xFF20282C),borderRadius:BorderRadius.circular(12)),
          child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.end,children:[
            if(message['replyTo'] is Map) _quotedMessage(Map<String,dynamic>.from(message['replyTo'])),
            Align(alignment:Alignment.centerLeft,widthFactor:1,child:body),
            Row(mainAxisSize:MainAxisSize.min,children:[Text(_time(message['createdAt']),style:const TextStyle(fontSize:10,color:Colors.white54)),if(me)...[const SizedBox(width:3),_ticks(status)]])
          ]),
        ),
      ),
    ));
  }

  Widget _interactive(Map<String,dynamic> message, Widget child) {
    final id=message['id']?.toString()??'';
    final active=_selectedIds.contains(id);
    final content = active
        ? Container(decoration:BoxDecoration(color:const Color(0x443EA6FF),borderRadius:BorderRadius.circular(14)),child:child)
        : child;
    return _SwipeReply(
      offset: _swipeOffsets[id] ?? 0,
      onOffsetChanged: (v) => setState(() => _swipeOffsets[id] = v),
      onReply: () => _startReply(message),
      onLongPress: () => _longSelect(message),
      onTap: _selectedIds.isNotEmpty ? () => _toggleSelect(message) : null,
      child: content,
    );
  }

  Widget _mediaDownloadButton(Map<String,dynamic> message, String size) { final id=(message['id']??'').toString(); return Material(color:Colors.black54,borderRadius:BorderRadius.circular(28),child:InkWell(borderRadius:BorderRadius.circular(28),onTap:_downloadingMedia.contains(id)?null:()=>_downloadMediaToCache(message),child:Padding(padding:const EdgeInsets.symmetric(horizontal:14,vertical:9),child:_downloadingMedia.contains(id)?const SizedBox(width:22,height:22,child:CircularProgressIndicator(strokeWidth:2.2,color:Colors.white)):Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.download_rounded,color:Colors.white,size:21),const SizedBox(width:7),Text(size.isEmpty?'Download':size,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700))])))); }

  Future<void> _showStickerActions(Map<String,dynamic> message) async {
    await showModalBottomSheet(context:context,backgroundColor:const Color(0xFF10171A),builder:(c)=>SafeArea(child:Wrap(children:[
      ListTile(leading:const Icon(Icons.star_border),title:const Text('Tambah Ke Favorit'),onTap:()async{Navigator.pop(c);await _favoriteIncomingSticker(message);}),
      ListTile(leading:const Icon(Icons.send),title:const Text('Kirim ulang'),onTap:()async{Navigator.pop(c);final path=_downloadedMediaPaths[message['id']?.toString()];if(path!=null)await _sendSticker(path);}),
    ])));
  }

  Widget _ticks(String status) {
    IconData icon = Icons.check;
    Color color = Colors.white54;

    if (status == 'failed') {
      icon = Icons.close;
      color = Colors.redAccent;
    } else if (status == 'read') {
      icon = Icons.done_all;
      color = const Color(0xFF53BDEB);
    } else if (status == 'sent' || status == 'delivered') {
      icon = Icons.done_all;
    } else if (status == 'sending') {
      return const SizedBox(
        width: 15,
        height: 15,
        child: Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
      );
    }

    return Icon(icon, color: color, size: 15);
  }
  String _time(dynamic v){final d=DateTime.tryParse(v?.toString()??'')?.toLocal();if(d==null)return'';return'${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';}
  Widget _composer() => Column(mainAxisSize:MainAxisSize.min,children:[
    if(_replyingTo!=null) Container(color:const Color(0xFF121B1E),padding:const EdgeInsets.fromLTRB(12,8,8,8),child:Row(children:[Expanded(child:_quotedMessage(_replyingTo)),IconButton(onPressed:()=>setState(()=>_replyingTo=null),icon:const Icon(Icons.close))])),
    if(_showStickerTray) _stickerTray(),
    Container(decoration:const BoxDecoration(color:Color(0xFF10171A),border:Border(top:BorderSide(color:Colors.white10))),padding:const EdgeInsets.fromLTRB(8,8,8,10),child:Row(crossAxisAlignment:CrossAxisAlignment.end,children:[
      IconButton(tooltip:'Sticker',onPressed:sendingMedia?null:()async{if(_stickers.isEmpty){await _createSticker();if(mounted&&_stickers.isNotEmpty)setState(()=>_showStickerTray=true);return;}if(mounted)setState(()=>_showStickerTray=!_showStickerTray);},icon:const Icon(Icons.sticky_note_2_outlined)),
      Expanded(child:TextField(controller:input,minLines:1,maxLines:5,textInputAction:TextInputAction.newline,decoration:InputDecoration(hintText:'Tulis pesan...',filled:true,fillColor:const Color(0xFF20282C),prefixIcon:IconButton(onPressed:sendingMedia?null:sendMedia,icon:const Icon(Icons.add_circle_outline)),border:OutlineInputBorder(borderRadius:BorderRadius.circular(25),borderSide:BorderSide.none),contentPadding:const EdgeInsets.symmetric(horizontal:14,vertical:11)))),
      const SizedBox(width:5),
      ValueListenableBuilder<TextEditingValue>(valueListenable:input,builder:(_,v,__){final has=v.text.trim().isNotEmpty;return Container(width:48,height:48,decoration:const BoxDecoration(shape:BoxShape.circle,gradient:LinearGradient(colors:[Color(0xFF7B61FF),Color(0xFF20C76B)])),child:IconButton(onPressed:sendingMedia?null:(has?sendText:_takePhoto),icon:Icon(has?Icons.send_rounded:Icons.camera_alt_rounded,color:Colors.white)));}),
    ])),
  ]);

  Widget _stickerTray(){
    return Container(height:154,color:const Color(0xFF151C20),padding:const EdgeInsets.symmetric(vertical:10),child:Row(children:[
      IconButton(tooltip:'Buat Sticker Anda',onPressed:_createSticker,icon:const Icon(Icons.add_circle_outline)),
      Expanded(child:_stickers.isEmpty?const Center(child:Text('Buat Sticker Anda')):ListView.separated(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:8),itemCount:_stickers.length,itemBuilder:(_,i){final path=_stickers[i];return GestureDetector(onTap:()=>_sendSticker(path),child:Container(width:112,height:112,padding:const EdgeInsets.all(8),decoration:BoxDecoration(color:const Color(0xFF20282C),borderRadius:BorderRadius.circular(16)),child:Image.file(File(path),fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Icon(Icons.broken_image))));},separatorBuilder:(_,__)=>const SizedBox(width:10))),
    ]));
  }

  String _formatBytes(dynamic raw){
    final n=int.tryParse(raw?.toString()??'')??0;
    if(n<=0)return'';
    if(n<1024)return '$n B';
    if(n<1024*1024)return '${(n/1024).toStringAsFixed(n<10*1024?1:0)} KB';
    return '${(n/(1024*1024)).toStringAsFixed(n<10*1024*1024?1:0)} MB';
  }

  String _mediaExt(Map<String,dynamic> message) {
    final name=(message['fileName']??'').toString().toLowerCase();
    final match=RegExp(r'\.([a-z0-9]{2,5})$').firstMatch(name);
    if(match!=null)return match.group(1)!;
    return message['type']=='video'?'mp4':'png';
  }

  Future<File> _localMediaFile(Map<String,dynamic> message) async {
    final dir=await getApplicationDocumentsDirectory();
    final mediaDir=Directory('${dir.path}/chatwithu_media');
    final safe=base64Url.encode(utf8.encode((message['id']??'').toString())).replaceAll('=','');
    return File('${mediaDir.path}/$safe.${_mediaExt(message)}');
  }

  Future<void> _restoreLocalMedia() async {
    final restored=<String,String>{};
    for(final m in messages){
      if(m['type']!='image'&&m['type']!='video'&&m['type']!='sticker')continue;
      final id=m['id']?.toString();
      if(id==null||id.isEmpty)continue;
      final f=await _localMediaFile(m);
      if(await f.exists())restored[id]=f.path;
    }
    if(restored.isNotEmpty&&mounted)setState(()=>_downloadedMediaPaths.addAll(restored));
  }

  Future<void> _downloadMediaToCache(Map<String,dynamic> message) async {
    final id=(message['id']??'').toString();
    if(id.isEmpty||widget.session.token==null)return;
    if(mounted)setState(()=>_downloadingMedia.add(id));
    try{
      final res=await api.downloadMedia(widget.session.token!,id);
      if(res.statusCode!=200) {
        dynamic data; try{data=jsonDecode(res.body);}catch(_){data=null;}
        throw Exception(data is Map?(data['message']??'HTTP ${res.statusCode}').toString():'HTTP ${res.statusCode}');
      }
      final local=await _localMediaFile(message);
      await local.parent.create(recursive:true);
      await local.writeAsBytes(res.bodyBytes,flush:true);
      _downloadedMediaPaths[id]=local.path;

      // The recipient's first successful fetch also saves the media directly
      // into the device gallery. The server has already removed its relay copy
      // after completing this download.
      final name=(message['fileName']??'ChatWithU_${DateTime.now().millisecondsSinceEpoch}.${_mediaExt(message)}').toString();
      SaveResult saveResult;
      if(message['type']=='video'){
        saveResult=await SaverGallery.saveFile(filePath:local.path,fileName:name,skipIfExists:false);
      }else{
        saveResult=await SaverGallery.saveImage(Uint8List.fromList(res.bodyBytes),fileName:name,skipIfExists:false);
      }
      if(mounted){
        setState((){});
        final ok=saveResult.isSuccess;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(ok?'Berhasil diunduh & disimpan ke galeri':'Berhasil diunduh, tapi gagal menyimpan ke galeri')));
      }
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Gagal mengunduh: $e')));
    }finally{
      if(mounted)setState(()=>_downloadingMedia.remove(id));
    }
  }

  Future<void> _openImageViewer(String url, Map<String,dynamic> message, {String? localPath}) async{
    final id=(message['id']??url).toString();
    String? path=localPath??_downloadedMediaPaths[id];
    if(path==null||path.isEmpty||!File(path).existsSync()){
      final local=await _localMediaFile(message);
      if(await local.exists())path=local.path;
    }
    if(path==null||path.isEmpty||!File(path).existsSync())return;
    if(!mounted)return;
    final resolvedPath = path;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ImageViewerPage(
          path: resolvedPath,
          message: message,
          onSave: () => _saveImageToGallery(resolvedPath, message),
        ),
      ),
    );
  }

  Future<void> _saveImageToGallery(String path, Map<String,dynamic> message) async{
    try{
      final bytes=await File(path).readAsBytes();
      final name=(message['fileName']??'ChatWithU_${DateTime.now().millisecondsSinceEpoch}.jpg').toString();
      final result=await SaverGallery.saveImage(Uint8List.fromList(bytes),fileName:name,skipIfExists:false);
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(result.isSuccess?'Tersimpan di galeri':'Gagal menyimpan')));
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Gagal menyimpan: $e')));
    }
  }

  Future<void> _openVideoViewer(String path, Map<String,dynamic> message) async {
    if (!File(path).existsSync() || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _VideoViewerPage(path: path, message: message)));
  }

  Future<void> _downloadFilePlaceholder(String url) async{try{final res=await http.get(Uri.parse(url));final dir=await getApplicationDocumentsDirectory();final f=File('${dir.path}/download_${DateTime.now().millisecondsSinceEpoch}');await f.writeAsBytes(res.bodyBytes);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('File tersimpan: ${f.path}')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Gagal: $e')));}}
}


class _MediaMessageBubble extends StatefulWidget {
  final String type;
  final String url;
  final String previewUrl;
  final String? localPath;
  final bool downloaded;
  final bool isMine;
  final String caption;
  final String size;
  final String time;
  final String status;
  final bool downloading;
  final VoidCallback onDownload;
  final VoidCallback onOpenImage;
  final VoidCallback? onOpenVideo;
  final double maxWidth;
  final double maxHeight;

  const _MediaMessageBubble({
    super.key,
    required this.type,
    required this.url,
    required this.previewUrl,
    required this.localPath,
    required this.downloaded,
    required this.isMine,
    required this.caption,
    required this.size,
    required this.time,
    required this.status,
    required this.downloading,
    required this.onDownload,
    required this.onOpenImage,
    required this.onOpenVideo,
    required this.maxWidth,
    required this.maxHeight,
  });

  @override
  State<_MediaMessageBubble> createState()=>_MediaMessageBubbleState();
}

class _MediaMessageBubbleState extends State<_MediaMessageBubble> {
  double _aspect=16/9;
  VideoPlayerController? _video;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  @override
  void initState(){
    super.initState();
    if(widget.type=='video'){
      if(widget.localPath!=null) _initVideo(widget.localPath!);
    }else{
      _resolveImage();
    }
  }

  @override
  void didUpdateWidget(covariant _MediaMessageBubble oldWidget){
    super.didUpdateWidget(oldWidget);
    if(widget.type!=oldWidget.type||widget.localPath!=oldWidget.localPath||widget.previewUrl!=oldWidget.previewUrl){
      if(widget.type=='video'){
        _disposeVideo();
        if(widget.localPath!=null) _initVideo(widget.localPath!);
      }else{
        _resolveImage();
      }
    }
  }

  void _resolveImage(){
    _imageStream?.removeListener(_imageListener!);
    final ImageProvider provider=widget.localPath!=null
        ? FileImage(File(widget.localPath!))
        : NetworkImage(widget.previewUrl);
    final stream=provider.resolve(const ImageConfiguration());
    final listener=ImageStreamListener((info,_) {
      final w=info.image.width.toDouble();
      final h=info.image.height.toDouble();
      if(w>0&&h>0&&mounted){
        final ratio=w/h;
        if(ratio>0.08&&ratio<12&&ratio!=_aspect)setState(()=>_aspect=ratio);
      }
    });
    _imageStream=stream;
    _imageListener=listener;
    stream.addListener(listener);
  }

  Future<void> _initVideo(String path) async {
    try{
      final c=VideoPlayerController.file(File(path));
      _video=c;
      await c.initialize();
      if(!mounted){await c.dispose();return;}
      final ratio=c.value.aspectRatio;
      if(ratio>0) setState(()=>_aspect=ratio);
    }catch(_){ }
  }

  void _disposeVideo(){
    final c=_video;
    _video=null;
    c?.dispose();
  }

  @override
  void dispose(){
    if(_imageStream!=null&&_imageListener!=null)_imageStream!.removeListener(_imageListener!);
    _disposeVideo();
    super.dispose();
  }

  Size _frameSize(){
    final safeAspect=(_aspect.isFinite&&_aspect>0)?_aspect:16/9;
    var w=widget.maxWidth;
    var h=w/safeAspect;
    if(h>widget.maxHeight){
      h=widget.maxHeight;
      w=h*safeAspect;
    }
    return Size(w,h);
  }

  Widget _media(Size size){
    final radius=BorderRadius.circular(10);
    if(widget.type=='image'){
      final image=widget.localPath!=null
          ? Image.file(File(widget.localPath!),width:size.width,height:size.height,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.broken_image,color:Colors.white,size:42)))
          : Image.network(widget.previewUrl,width:size.width,height:size.height,fit:BoxFit.cover,errorBuilder:(_,__,___)=>Container(color:Colors.black45,child:const Center(child:Icon(Icons.image_outlined,color:Colors.white54,size:42))));
      return ClipRRect(borderRadius:radius,child:GestureDetector(onTap:widget.downloaded||widget.isMine?widget.onOpenImage:null,child:Stack(fit:StackFit.expand,children:[image,if(!widget.downloaded&&!widget.isMine)Center(child:_downloadButton())])));
    }

    final c=_video;
    if(widget.downloaded&&c!=null&&c.value.isInitialized){
      return ClipRRect(borderRadius:radius,child:GestureDetector(onTap:widget.onOpenVideo,child:Stack(fit:StackFit.expand,children:[
        VideoPlayer(c),
        Container(color:Colors.black26),
        const Center(child:DecoratedBox(decoration:BoxDecoration(color:Colors.white,shape:BoxShape.circle),child:Padding(padding:EdgeInsets.all(10),child:Icon(Icons.play_arrow_rounded,color:Colors.black,size:34)))),
        Positioned(left:8,right:8,bottom:7,child:VideoProgressIndicator(c,allowScrubbing:false,padding:EdgeInsets.zero,colors:const VideoProgressColors(playedColor:Colors.white,bufferedColor:Colors.white54,backgroundColor:Colors.white24))),
      ])));
    }

    return ClipRRect(borderRadius:radius,child:Stack(fit:StackFit.expand,children:[
      Container(color:Colors.black45),
      const Center(child:Icon(Icons.videocam_rounded,size:46,color:Colors.white54)),
      if(!widget.downloaded&&!widget.isMine)Center(child:_downloadButton()),
    ]));
  }

  Widget _downloadButton(){
    return Material(color:Colors.black54,borderRadius:BorderRadius.circular(28),child:InkWell(borderRadius:BorderRadius.circular(28),onTap:widget.downloading?null:widget.onDownload,child:Padding(padding:const EdgeInsets.symmetric(horizontal:14,vertical:9),child:widget.downloading
      ? const SizedBox(width:22,height:22,child:CircularProgressIndicator(strokeWidth:2.2,color:Colors.white))
      : Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.download_rounded,color:Colors.white,size:21),const SizedBox(width:7),Text(widget.size.isEmpty?'Download':widget.size,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700))]))));
  }

  @override
  Widget build(BuildContext context){
    final size=_frameSize();
    final bg=widget.isMine?const Color(0xFF2A6B55):const Color(0xFF20282C);
    return Container(
      margin:const EdgeInsets.only(bottom:5),
      width:size.width,
      decoration:BoxDecoration(color:bg,borderRadius:BorderRadius.circular(12)),
      clipBehavior:Clip.antiAlias,
      child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        SizedBox(width:size.width,height:size.height,child:_media(size)),
        if(widget.caption.isNotEmpty)
          Padding(padding:const EdgeInsets.fromLTRB(10,8,10,2),child:Text(widget.caption,style:const TextStyle(fontSize:14),softWrap:true)),
        Padding(padding:const EdgeInsets.fromLTRB(8,2,8,6),child:Row(mainAxisAlignment:MainAxisAlignment.end,children:[Text(widget.time,style:const TextStyle(fontSize:10,color:Colors.white54)),if(widget.isMine)...[const SizedBox(width:3),_ticks(widget.status)]])),
      ]),
    );
  }

  Widget _ticks(String status){
    IconData icon=Icons.check;
    Color color=Colors.white54;
    if(status=='failed'){
      icon=Icons.close;
      color=Colors.redAccent;
    }else if(status=='read'){
      icon=Icons.done_all;
      color=const Color(0xFF53BDEB);
    }else if(status=='sent'||status=='delivered'){
      icon=Icons.done_all;
    }else if(status=='sending'){
      return const SizedBox(width:15,height:15,child:Padding(padding:EdgeInsets.all(2),child:CircularProgressIndicator(strokeWidth:1.6)));
    }
    return Icon(icon,color:color,size:15);
  }
}


class _MediaComposeResult {
  final String caption;
  const _MediaComposeResult(this.caption);
}

class _MediaComposerPage extends StatefulWidget {
  final File file;
  final String type;
  final String recipientName;

  const _MediaComposerPage({
    required this.file,
    required this.type,
    required this.recipientName,
  });

  @override
  State<_MediaComposerPage> createState() => _MediaComposerPageState();
}

class _MediaComposerPageState extends State<_MediaComposerPage> {
  final caption = TextEditingController();
  VideoPlayerController? _video;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    if (widget.type == 'video') _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final c = VideoPlayerController.file(widget.file);
      _video = c;
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _videoReady = true);
    } catch (_) {}
  }

  @override
  void dispose() {
    caption.dispose();
    _video?.dispose();
    super.dispose();
  }

  void _send() {
    Navigator.pop(context, _MediaComposeResult(caption.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.type == 'video';
    final c = _video;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
        title: Text(widget.recipientName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: isVideo
                    ? (_videoReady && c != null && c.value.isInitialized
                        ? GestureDetector(
                            onTap: () => setState(() {
                              c.value.isPlaying ? c.pause() : c.play();
                            }),
                            child: AspectRatio(
                              aspectRatio: c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  VideoPlayer(c),
                                  if (!c.value.isPlaying)
                                    const Center(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                        child: Padding(
                                          padding: EdgeInsets.all(12),
                                          child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 42),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          )
                        : const CircularProgressIndicator())
                    : InteractiveViewer(
                        minScale: .8,
                        maxScale: 4,
                        child: Image.file(
                          widget.file,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white, size: 48),
                        ),
                      ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: const BoxDecoration(
                color: Color(0xFF10171A),
                border: Border(top: BorderSide(color: Colors.white10)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: caption,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 500,
                      decoration: InputDecoration(
                        hintText: 'Tambah keterangan...',
                        counterText: '',
                        filled: true,
                        fillColor: const Color(0xFF20282C),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 50,
                    height: 50,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF20C76B),
                    ),
                    child: IconButton(
                      onPressed: _send,
                      icon: const Icon(Icons.send_rounded, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoBubble extends StatefulWidget {
  final String path;
  const _VideoBubble({required this.path});

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.file(File(widget.path));
      _controller = c;
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _ready = true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (!_ready || c == null || !c.value.isInitialized) {
      return Container(width: 230, height: 160, color: Colors.black45, child: const Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final aspect = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300, maxHeight: 360),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: aspect,
        child: Stack(fit: StackFit.expand, children: [
          VideoPlayer(c),
          Container(color: Colors.black26),
          const Center(child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: Padding(padding: EdgeInsets.all(10), child: Icon(Icons.play_arrow_rounded, color: Colors.black, size: 34)),
          )),
          Positioned(left: 8, right: 8, bottom: 7, child: VideoProgressIndicator(c, allowScrubbing: false, padding: EdgeInsets.zero, colors: const VideoProgressColors(playedColor: Colors.white, bufferedColor: Colors.white54, backgroundColor: Colors.white24))),
          ]),
        ),
      ),
    );
  }
}

class _VideoViewerPage extends StatefulWidget {
  final String path;
  final Map<String, dynamic> message;
  const _VideoViewerPage({required this.path, required this.message});

  @override
  State<_VideoViewerPage> createState() => _VideoViewerPageState();
}

class _VideoViewerPageState extends State<_VideoViewerPage> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.file(File(widget.path));
      _controller = c;
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      await c.play();
      setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _ready = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  String _caption() => (widget.message['caption']?.toString() ?? '').trim();

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const SizedBox.shrink()),
      body: !_ready || c == null || !c.value.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showControls = !_showControls),
              child: Stack(children: [
                Center(child: AspectRatio(aspectRatio: c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9, child: VideoPlayer(c))),
                if (_showControls)
                  Positioned(left: 12, right: 12, bottom: 12, child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 5),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                    child: Column(children: [
                      IconButton(onPressed: () { setState(() { c.value.isPlaying ? c.pause() : c.play(); }); }, iconSize: 36, color: Colors.white, icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill)),
                      VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.only(bottom: 2), colors: const VideoProgressColors(playedColor: Colors.white, bufferedColor: Colors.white54, backgroundColor: Colors.white24)),
                      if (_caption().isNotEmpty) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(top: 7, left: 4, right: 4), child: Text(_caption(), style: const TextStyle(color: Colors.white, fontSize: 14))))
                    ]),
                  )),
              ]),
            ),
    );
  }
}

class _ImageViewerPage extends StatelessWidget {
  final String path;
  final Map<String, dynamic> message;
  final VoidCallback onSave;

  const _ImageViewerPage({
    required this.path,
    required this.message,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const SizedBox.shrink(),
        actions: [
          IconButton(
            tooltip: 'Simpan ke galeri',
            onPressed: onSave,
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          return InteractiveViewer(
            constrained: false,
            clipBehavior: Clip.none,
            minScale: 1,
            maxScale: 6,
            boundaryMargin: const EdgeInsets.all(2000),
            child: SizedBox(
              width: width,
              height: height,
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AttachmentChoice extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _AttachmentChoice({required this.icon, required this.label, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: BoxDecoration(color: color.withValues(alpha: .13), borderRadius: BorderRadius.circular(18), border: Border.all(color: color.withValues(alpha: .25))),
      child: Column(children: [Icon(icon, color: color, size: 28), const SizedBox(height: 6), Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))]),
    ),
  );
}

class _TypingText extends StatefulWidget{const _TypingText({super.key});@override State<_TypingText> createState()=>_TypingTextState();}
class _TypingTextState extends State<_TypingText> with SingleTickerProviderStateMixin{late final AnimationController c;@override void initState(){super.initState();c=AnimationController(vsync:this,duration:const Duration(milliseconds:900))..repeat();}@override void dispose(){c.dispose();super.dispose();}@override Widget build(BuildContext context)=>AnimatedBuilder(animation:c,builder:(_,__) {final t=c.value*math.pi*2;return Row(children:[const Text('Mengetik',style:TextStyle(fontSize:12,color:Color(0xFF5FD18A))),const SizedBox(width:2),for(int i=0;i<3;i++)Transform.translate(offset:Offset(0,-math.sin(t+i*1.1)*2.3),child:const Text('.',style:TextStyle(fontSize:14,color:Color(0xFF5FD18A))))]);});}

class _ChatSearchDelegate extends SearchDelegate<String>{final Api api;final String token;final String username;final List<Map<String,dynamic>> localMessages;_ChatSearchDelegate({required this.api,required this.token,required this.username,required this.localMessages});List<Map<String,dynamic>> _local(String q)=>localMessages.where((m)=>m['message']?.toString().toLowerCase().contains(q.toLowerCase())==true).toList();@override List<Widget>? buildActions(BuildContext c)=>[if(query.isNotEmpty)IconButton(onPressed:()=>query='',icon:const Icon(Icons.clear))];@override Widget? buildLeading(BuildContext c)=>IconButton(onPressed:()=>close(c,''),icon:const Icon(Icons.arrow_back));@override Widget buildResults(BuildContext context)=>_results(context);@override Widget buildSuggestions(BuildContext context)=>_results(context);Widget _results(BuildContext context){final q=query.trim();if(q.isEmpty)return const Center(child:Text('Ketik kata untuk mencari chat'));return FutureBuilder<List<dynamic>>(future:api.searchMessages(token,username,q),builder:(context,s){List<Map<String,dynamic>> rows=[];if(s.hasData){rows=s.data!.map((e)=>Map<String,dynamic>.from(e)).toList();}if(rows.isEmpty)rows=_local(q);if(rows.isEmpty)return const Center(child:Text('Tidak Ditemukan'));return ListView.builder(itemCount:rows.length,itemBuilder:(_,i){final m=rows[i];return ListTile(title:Text(m['message']?.toString()??m['fileName']?.toString()??''),subtitle:Text(m['createdAt']?.toString()??''));});});}}

class ChatMediaPage extends StatefulWidget{final Session session;final String username;final String contactName;const ChatMediaPage({super.key,required this.session,required this.username,required this.contactName});@override State<ChatMediaPage> createState()=>_ChatMediaPageState();}
class _ChatMediaPageState extends State<ChatMediaPage>{final api=Api();Map<String,dynamic> data={'media':[],'docs':[],'links':[]};bool loading=true;@override void initState(){super.initState();_load();}Future<void> _load()async{try{final d=await api.chatMedia(widget.session.token!,widget.username);if(mounted)setState(()=>data=d);}catch(_){}finally{if(mounted)setState(()=>loading=false);}}@override Widget build(BuildContext context)=>DefaultTabController(length:3,child:Scaffold(appBar:AppBar(title:Text(widget.contactName),bottom:const TabBar(tabs:[Tab(text:'Media'),Tab(text:'Dok'),Tab(text:'Tautan')])),body:loading?const Center(child:CircularProgressIndicator()):TabBarView(children:[_media(),_docs(),_links()])));Widget _empty(String text)=>Center(child:Text(text,style:const TextStyle(color:Colors.white54)));Widget _media(){final list=List<dynamic>.from(data['media']??[]);if(list.isEmpty)return _empty('Tidak ada media');return GridView.builder(padding:const EdgeInsets.all(2),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,crossAxisSpacing:2,mainAxisSpacing:2),itemCount:list.length,itemBuilder:(_,i){final m=Map<String,dynamic>.from(list[i]);final type=m['type'];final url=(m['url']??m['mediaUrl']??'').toString();return Stack(fit:StackFit.expand,children:[if(type=='image')Image.network((m['previewUrl']??url).toString(),fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.broken_image))else Container(color:Colors.black38,child:const Icon(Icons.play_circle_fill,size:42)),if(type=='video')const Positioned(right:5,bottom:5,child:Icon(Icons.videocam,size:16))]);});}Widget _docs(){final list=List<dynamic>.from(data['docs']??[]);if(list.isEmpty)return _empty('Tidak ada dokumen');return ListView.builder(itemCount:list.length,itemBuilder:(_,i){final m=Map<String,dynamic>.from(list[i]);return ListTile(leading:const Icon(Icons.insert_drive_file),title:Text(m['fileName']?.toString()??'Dokumen'),subtitle:Text(m['createdAt']?.toString()??''));});}Widget _links(){final list=List<dynamic>.from(data['links']??[]);if(list.isEmpty)return _empty('Tidak ada tautan');return ListView.builder(itemCount:list.length,itemBuilder:(_,i){final m=Map<String,dynamic>.from(list[i]);return ListTile(leading:const Icon(Icons.link),title:Text(m['message']?.toString()??''),subtitle:Text(m['createdAt']?.toString()??''));});}}

class _StickerMakerSheet extends StatefulWidget {
  final ImagePicker picker;
  const _StickerMakerSheet({required this.picker});
  @override
  State<_StickerMakerSheet> createState() => _StickerMakerSheetState();
}

class _StickerMakerSheetState extends State<_StickerMakerSheet> {
  final text = TextEditingController();
  Color color = const Color(0xFF7B61FF);
  XFile? photo;
  final colors = const [
    Color(0xFF7B61FF), Color(0xFF20C76B), Color(0xFFE05B8D),
    Color(0xFF3EA6FF), Color(0xFFFF8A3D), Color(0xFFB36BFF),
    Color(0xFF00A6A6), Color(0xFFE6B800),
  ];

  @override
  void dispose() { text.dispose(); super.dispose(); }

  Future<void> pickPhoto() async {
    final p = await widget.picker.pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 1800, maxHeight: 1800);
    if (p != null && mounted) setState(() => photo = p);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(child: Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)))),
        const SizedBox(height: 14),
        const Text('Buat Sticker Anda', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Container(
          height: 180,
          decoration: photo == null
              ? BoxDecoration(color: color, borderRadius: BorderRadius.circular(22))
              : BoxDecoration(borderRadius: BorderRadius.circular(22)),
          clipBehavior: Clip.antiAlias,
          child: photo == null
              ? Center(child: Text(text.text.isEmpty ? 'Sticker' : text.text, textAlign: TextAlign.center, maxLines: 4, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)))
              : Image.file(File(photo!.path), fit: BoxFit.contain),
        ),
        const SizedBox(height: 14),
        TextField(controller: text, maxLines: 3, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Teks sticker', hintText: 'Opsional — teks tetap bisa ditambahkan', border: OutlineInputBorder())),
        if (photo == null) ...[
          const SizedBox(height: 12),
          const Text('Warna background', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [for (final c in colors) GestureDetector(onTap: () => setState(() => color = c), child: Container(width: 38, height: 38, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: color == c ? Colors.white : Colors.white24, width: color == c ? 3 : 1))))]),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(onPressed: pickPhoto, icon: const Icon(Icons.photo_library_outlined), label: Text(photo == null ? 'Pakai Foto Jadi Sticker' : 'Ganti Foto')),
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: (photo == null && text.text.trim().isEmpty) ? null : () => Navigator.pop(context, {'text': text.text.trim(), 'color': color, 'photo': photo}), icon: const Icon(Icons.check_circle_outline), label: const Text('Simpan Sticker')),
      ])),
    ));
  }
}

class _SwipeReply extends StatefulWidget {
  final double offset;
  final ValueChanged<double> onOffsetChanged;
  final VoidCallback onReply;
  final VoidCallback onLongPress;
  final VoidCallback? onTap;
  final Widget child;
  const _SwipeReply({required this.offset, required this.onOffsetChanged, required this.onReply, required this.onLongPress, required this.onTap, required this.child});
  @override State<_SwipeReply> createState() => _SwipeReplyState();
}
class _SwipeReplyState extends State<_SwipeReply> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _drag = 0;
  @override void initState(){super.initState();_controller=AnimationController(vsync:this,duration:const Duration(milliseconds:180));}
  @override void dispose(){_controller.dispose();super.dispose();}
  void _snapBack(){final start=_drag;_controller..reset()..addListener((){widget.onOffsetChanged(start*(1-_controller.value));})..forward();}
  @override Widget build(BuildContext context){
    final shown=_drag>0?_drag:widget.offset;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: widget.onLongPress,
      onTap: widget.onTap,
      onHorizontalDragUpdate:(d){if(d.delta.dx<=0 && _drag<=0)return;_drag=(_drag+d.delta.dx).clamp(0.0,96.0);widget.onOffsetChanged(_drag);},
      onHorizontalDragEnd:(_){if(_drag>=64)widget.onReply();_snapBack();},
      child: Stack(children:[
        Positioned.fill(child:Align(alignment:Alignment.centerLeft,child:Opacity(opacity:(shown/64).clamp(0.0,1.0),child:const Padding(padding:EdgeInsets.only(left:8),child:Icon(Icons.reply_rounded,color:Color(0xFF62D696),size:22))))),
        Transform.translate(offset:Offset(shown,0),child:widget.child),
      ]),
    );
  }
}
