import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:saver_gallery/saver_gallery.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api.dart';
import '../services/session.dart';
import '../services/socket_service.dart';
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
    _connectSocket();
    load();
    pollTimer = Timer.periodic(const Duration(seconds: 8), (_) { if (!socket.connected) syncMessages(); });
  }

  void _connectSocket() {
    if (widget.session.token == null) return;
    socket.connect(Api.baseUrl, widget.session.token!);
    socket.on('message:new', _onSocketMessage);
    socket.on('typing', _onTyping);
    socket.on('message:read', _onRead);
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
    if (sender == username) remoteTyping = false;
    if (mounted) setState(() {});
    if (sender == username || recipient == widget.session.username) _bottom();
  }

  void _onTyping(dynamic raw) {
    if (raw is! Map) return;
    if (raw['from']?.toString() != username) return;
    final value = raw['typing'] == true;
    if (mounted && remoteTyping != value) setState(() => remoteTyping = value);
  }

  void _onRead(dynamic raw) {
    if (raw is! Map || raw['username']?.toString() != username) return;
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      if (messages[i]['senderUsername']?.toString() == widget.session.username && messages[i]['status'] != 'read') {
        messages[i] = {...messages[i], 'status': 'read'};
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
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
    await _markRead();
    _bottom(jump: true);
  }

  Future<void> _markRead() async {
    final token = widget.session.token;
    if (token == null) return;
    final latest = messages.isEmpty ? DateTime.now().toUtc() : _newestDate() ?? DateTime.now().toUtc();
    await LocalCache.markRead(username, latest.toUtc().toIso8601String());
    try {
      await api.markRead(token, username);
      socket.emit('message:read', {'other': username});
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
    final temp = {'id':'local-${DateTime.now().microsecondsSinceEpoch}','type':'text','message':text,'senderUsername':widget.session.username,'recipientUsername':username,'status':'sending','createdAt':DateTime.now().toUtc().toIso8601String()};
    messages = [...messages, temp]; if (mounted) setState(() {}); _bottom();
    try {
      final result = await api.sendMessage(widget.session.token!, username, text);
      _mergeMessages([result]);
      await LocalCache.saveMessages(username, messages);
      if (mounted) setState(() {}); _bottom();
    } on ApiException catch (e) {
      if (e.status == 403) return _showBanned();
      _markFailed(temp['id'].toString());
    } catch (_) { _markFailed(temp['id'].toString()); }
  }

  void _markFailed(String id) { final i=messages.indexWhere((m)=>m['id']?.toString()==id); if(i>=0){messages[i]={...messages[i],'status':'failed'};if(mounted)setState((){});} }

  Future<void> _sendPickedMedia(XFile picked, {required String type}) async {
    final file = File(picked.path);
    final fileName = picked.name;
    try {
      final size = await file.length();
      if (size <= 0) throw Exception('Foto/video tidak dapat dibaca.');
      if (size > 50 * 1024 * 1024) throw Exception('File maksimal 50 MB.');

      if (type == 'image') {
        final approved = await _previewImage(file, fileName);
        if (!approved) return;
      }
      if (!mounted) return;
      setState(() => sendingMedia = true);
      final result = await api.uploadMedia(widget.session.token!, username, file, type: type);
      _mergeMessages([result]);
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

  Future<bool> _previewImage(File file, String fileName) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF10171A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)))),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: Image.file(file, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 12),
              Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(sheetContext, false), child: const Text('Batal'))),
                const SizedBox(width: 10),
                Expanded(child: FilledButton.icon(onPressed: () => Navigator.pop(sheetContext, true), icon: const Icon(Icons.send_rounded), label: const Text('Kirim'))),
              ]),
            ],
          ),
        ),
      ),
    );
    return result == true;
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

  Future<void> _rename() async {
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
        title: Row(
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
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'rename': _rename(); break;
                case 'media': Navigator.push(context, MaterialPageRoute(builder: (_) => ChatMediaPage(session: widget.session, username: username, contactName: contactName))); break;
                case 'clear': _clearChat(); break;
                case 'search': _searchChat(); break;
                case 'theme': _theme(); break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'search', child: Text('Cari')),
              PopupMenuItem(value: 'media', child: Text('Media, tautan, dan dok')),
              PopupMenuItem(value: 'rename', child: Text('Ganti nama kontak')),
              PopupMenuItem(value: 'clear', child: Text('Bersihkan chat')),
              PopupMenuItem(value: 'theme', child: Text('Tema obrolan')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
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
        ],
      ),
    );
  }

  Widget _wallpaper(){if(wallpaperPath!=null&&wallpaperPath!.isNotEmpty&&File(wallpaperPath!).existsSync())return Image.file(File(wallpaperPath!),key:ValueKey(wallpaperPath),fit:BoxFit.cover);return Image.asset('assets/chat_background.jpg',fit:BoxFit.cover,alignment:Alignment.topCenter,filterQuality:FilterQuality.low);}
  Widget _dayChip(dynamic v)=>Padding(padding:const EdgeInsets.symmetric(vertical:8),child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:6),decoration:BoxDecoration(color:const Color(0xFF1E292D),borderRadius:BorderRadius.circular(12)),child:Text(_dayLabel(v),style:const TextStyle(fontSize:12,color:Colors.white70))));
  String _dayKey(dynamic v){final d=DateTime.tryParse(v?.toString()??'')?.toLocal();return d==null?'':'${d.year}-${d.month}-${d.day}';}
  String _dayLabel(dynamic v){final d=DateTime.tryParse(v?.toString()??'')?.toLocal();if(d==null)return'';final n=DateTime.now();final diff=DateTime(n.year,n.month,n.day).difference(DateTime(d.year,d.month,d.day)).inDays;if(diff==0)return'Hari Ini';if(diff==1)return'Kemarin';const m=['Januari','Februari','Maret','April','Mei','Juni','Juli','Agustus','September','Oktober','November','Desember'];return'${d.day} ${m[d.month-1]} ${d.year}';}

  Widget _bubble(Map<String,dynamic> message){final me=(message['senderUsername']??message['sender'])==widget.session.username;final type=message['type']??'text';Widget body;if(type=='image'||type=='video'){final url=(message['url']??message['mediaUrl']??'').toString();body=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[if(url.isNotEmpty)Container(width:230,height:160,clipBehavior:Clip.antiAlias,decoration:BoxDecoration(borderRadius:BorderRadius.circular(10)),child:type=='image'?Image.network(url,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Center(child:Icon(Icons.broken_image))):Stack(fit:StackFit.expand,children:[Container(color:Colors.black45),const Center(child:Icon(Icons.play_circle_fill,size:54,color:Colors.white))])),Row(mainAxisSize:MainAxisSize.min,children:[Text(type=='video'?'Video':'Foto',style:const TextStyle(fontSize:12)),IconButton(onPressed:url.isEmpty?null:()=>_download(url,type),icon:const Icon(Icons.download,size:18))])]);}else if(type=='file'){final url=(message['url']??message['mediaUrl']??'').toString();final name=(message['fileName']??message['name']??message['message']??'File').toString();body=Row(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.insert_drive_file_outlined,size:34),const SizedBox(width:9),Flexible(child:Text(name,maxLines:2,overflow:TextOverflow.ellipsis)),if(url.isNotEmpty)IconButton(onPressed:()=>_downloadFilePlaceholder(url),icon:const Icon(Icons.download,size:18))]);}else{body=Text(message['message']?.toString()??'',style:const TextStyle(fontSize:15));}
    final max=MediaQuery.sizeOf(context).width*.82;final status=message['status']?.toString()??'sent';return Align(alignment:me?Alignment.centerRight:Alignment.centerLeft,child:ConstrainedBox(key:ValueKey(message['id']?.toString()),constraints:BoxConstraints(maxWidth:max),child:Container(margin:const EdgeInsets.only(bottom:5),padding:const EdgeInsets.fromLTRB(12,8,8,6),decoration:BoxDecoration(color:me?const Color(0xFF2A6B55):const Color(0xFF20282C),borderRadius:BorderRadius.circular(12)),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.end,children:[Align(alignment:Alignment.centerLeft,widthFactor:1,child:body),Row(mainAxisSize:MainAxisSize.min,children:[Text(_time(message['createdAt']),style:const TextStyle(fontSize:10,color:Colors.white54)),if(me)...[const SizedBox(width:3),_ticks(status)]])]))));}
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
  Widget _composer() => Container(
    decoration: const BoxDecoration(
      color: Color(0xFF10171A),
      border: Border(top: BorderSide(color: Colors.white10)),
    ),
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      IconButton(
        tooltip: 'Foto',
        onPressed: sendingMedia ? null : _pickPhoto,
        icon: const Icon(Icons.photo_rounded),
      ),
      Expanded(
        child: TextField(
          controller: input,
          minLines: 1,
          maxLines: 5,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            hintText: 'Tulis pesan...',
            filled: true,
            fillColor: const Color(0xFF20282C),
            prefixIcon: IconButton(onPressed: sendingMedia ? null : sendMedia, icon: const Icon(Icons.add_circle_outline)),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          ),
        ),
      ),
      const SizedBox(width: 5),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: input,
        builder: (_, v, __) {
          final has = v.text.trim().isNotEmpty;
          return Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color(0xFF7B61FF), Color(0xFF20C76B)])),
            child: IconButton(onPressed: sendingMedia ? null : (has ? sendText : _takePhoto), icon: Icon(has ? Icons.send_rounded : Icons.camera_alt_rounded, color: Colors.white)),
          );
        },
      ),
    ]),
  );

  Future<void> _download(String url,String type) async{try{final res=await http.get(Uri.parse(url));if(res.statusCode!=200)throw Exception('HTTP ${res.statusCode}');if(type=='video'){final dir=await getApplicationDocumentsDirectory();final f=File('${dir.path}/ChatWithU_${DateTime.now().millisecondsSinceEpoch}.mp4');await f.writeAsBytes(res.bodyBytes);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Video tersimpan: ${f.path}')));return;}final bytes=Uint8List.fromList(res.bodyBytes);final result=await SaverGallery.saveImage(bytes,fileName:'ChatWithU_${DateTime.now().millisecondsSinceEpoch}.jpg',skipIfExists:false);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(result.isSuccess?'Tersimpan di galeri':'Gagal menyimpan')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Gagal mengunduh: $e')));}}
  Future<void> _downloadFilePlaceholder(String url) async{try{final res=await http.get(Uri.parse(url));final dir=await getApplicationDocumentsDirectory();final f=File('${dir.path}/download_${DateTime.now().millisecondsSinceEpoch}');await f.writeAsBytes(res.bodyBytes);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('File tersimpan: ${f.path}')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Gagal: $e')));}}
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
class _ChatMediaPageState extends State<ChatMediaPage>{final api=Api();Map<String,dynamic> data={'media':[],'docs':[],'links':[]};bool loading=true;@override void initState(){super.initState();_load();}Future<void> _load()async{try{final d=await api.chatMedia(widget.session.token!,widget.username);if(mounted)setState(()=>data=d);}catch(_){}finally{if(mounted)setState(()=>loading=false);}}@override Widget build(BuildContext context)=>DefaultTabController(length:3,child:Scaffold(appBar:AppBar(title:Text(widget.contactName),bottom:const TabBar(tabs:[Tab(text:'Media'),Tab(text:'Dok'),Tab(text:'Tautan')])),body:loading?const Center(child:CircularProgressIndicator()):TabBarView(children:[_media(),_docs(),_links()])));Widget _empty(String text)=>Center(child:Text(text,style:const TextStyle(color:Colors.white54)));Widget _media(){final list=List<dynamic>.from(data['media']??[]);if(list.isEmpty)return _empty('Tidak ada media');return GridView.builder(padding:const EdgeInsets.all(2),gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,crossAxisSpacing:2,mainAxisSpacing:2),itemCount:list.length,itemBuilder:(_,i){final m=Map<String,dynamic>.from(list[i]);final type=m['type'];final url=(m['url']??m['mediaUrl']??'').toString();return Stack(fit:StackFit.expand,children:[if(type=='image')Image.network(url,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const Icon(Icons.broken_image))else Container(color:Colors.black38,child:const Icon(Icons.play_circle_fill,size:42)),if(type=='video')const Positioned(right:5,bottom:5,child:Icon(Icons.videocam,size:16))]);});}Widget _docs(){final list=List<dynamic>.from(data['docs']??[]);if(list.isEmpty)return _empty('Tidak ada dokumen');return ListView.builder(itemCount:list.length,itemBuilder:(_,i){final m=Map<String,dynamic>.from(list[i]);return ListTile(leading:const Icon(Icons.insert_drive_file),title:Text(m['fileName']?.toString()??'Dokumen'),subtitle:Text(m['createdAt']?.toString()??''));});}Widget _links(){final list=List<dynamic>.from(data['links']??[]);if(list.isEmpty)return _empty('Tidak ada tautan');return ListView.builder(itemCount:list.length,itemBuilder:(_,i){final m=Map<String,dynamic>.from(list[i]);return ListTile(leading:const Icon(Icons.link),title:Text(m['message']?.toString()??''),subtitle:Text(m['createdAt']?.toString()??''));});}}
