import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const CloudBuilderApp());

class CloudBuilderApp extends StatelessWidget {
  const CloudBuilderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Flutter Cloud Builder',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6658D3)),
          scaffoldBackgroundColor: const Color(0xFFF6F6FB),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(), filled: true, fillColor: Colors.white,
          ),
        ),
        home: const BuilderHome(),
      );
}

class BuilderHome extends StatefulWidget {
  const BuilderHome({super.key});
  @override
  State<BuilderHome> createState() => _BuilderHomeState();
}

class _BuilderHomeState extends State<BuilderHome> {
  final owner = TextEditingController();
  final repo = TextEditingController();
  final branch = TextEditingController(text: 'main');
  final token = TextEditingController();
  Timer? ticker;
  DateTime? startedAt;
  Duration elapsed = Duration.zero;
  PlatformFile? selected;
  String status = 'Siap untuk build';
  String detail = 'Pilih ZIP proyek Flutter. Aplikasi otomatis mencari pubspec.yaml dan lib/main.dart meskipun ada di folder bertingkat.';
  String? runId;
  String? artifactUrl;
  String? artifactName;
  String? failureZipPath;
  String? uploadedSourcePath;
  bool busy = false;
  bool terminal = false;
  bool obscureToken = true;
  double progress = 0;
  String phase = 'Menunggu';
  final List<String> logs = [];
  static const api = 'https://api.github.com';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    ticker?.cancel();
    owner.dispose(); repo.dispose(); branch.dispose(); token.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    var bundledOwner = '';
    var bundledRepo = '';
    var bundledBranch = '';
    var bundledToken = '';
    try {
      final configText = await rootBundle.loadString('assets/github_config.json');
      final config = jsonDecode(configText) as Map<String, dynamic>;
      String readConfig(String key) => (config[key] ?? '').toString().trim();
      bundledOwner = readConfig('github_owner');
      bundledRepo = readConfig('github_repo');
      bundledBranch = readConfig('github_branch');
      final value = readConfig('github_token');
      if (value.isNotEmpty && value != 'PASTE_GITHUB_TOKEN_HERE') bundledToken = value;
    } catch (_) { /* JSON config is optional; saved settings can be used instead. */ }
    if (!mounted) return;
    setState(() {
      owner.text = bundledOwner.isNotEmpty && bundledOwner != 'GITHUB_USERNAME_OR_ORGANIZATION' ? bundledOwner : (p.getString('owner') ?? '');
      repo.text = bundledRepo.isNotEmpty && bundledRepo != 'REPOSITORY_NAME' ? bundledRepo : (p.getString('repo') ?? '');
      branch.text = bundledBranch.isNotEmpty ? bundledBranch : (p.getString('branch') ?? 'main');
      // JSON config takes priority so the APK uses the bundled GitHub configuration.
      token.text = bundledToken.isNotEmpty ? bundledToken : (p.getString('token') ?? '');
    });
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('owner', owner.text.trim());
    await p.setString('repo', repo.text.trim());
    await p.setString('branch', branch.text.trim().isEmpty ? 'main' : branch.text.trim());
    await p.setString('token', token.text.trim());
  }

  Map<String, String> get headers => {
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer ${token.text.trim()}',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Flutter-Cloud-Builder-Android',
      };

  String get repoPath => '${owner.text.trim()}/${repo.text.trim()}';
  Uri endpoint(String path) => Uri.parse('$api/repos/$repoPath/$path');

  void addLog(String s) {
    if (!mounted) return;
    setState(() {
      logs.insert(0, '[${DateTime.now().toLocal().toString().substring(11, 19)}] $s');
      if (logs.length > 80) logs.removeLast();
    });
  }

  Future<void> _pickZip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: const ['zip'], withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    if (f.path == null) {
      _message('File tidak bisa dibaca dari penyimpanan ini. Coba pilih ZIP lokal.');
      return;
    }
    setState(() { selected = f; status = 'File dipilih'; detail = f.name; });
  }

  Future<void> _startBuild() async {
    if (busy) return;
    if (owner.text.trim().isEmpty || repo.text.trim().isEmpty || token.text.trim().isEmpty) {
      _message('Isi GitHub owner, nama repository, dan token terlebih dahulu.'); return;
    }
    if (selected?.path == null) { _message('Pilih file ZIP proyek Flutter dulu.'); return; }
    final source = File(selected!.path!);
    if (!await source.exists()) { _message('File ZIP tidak ditemukan.'); return; }
    final length = await source.length();
    if (length > 24 * 1024 * 1024) {
      _message('ZIP lebih dari 24 MB. GitHub Contents API punya batas ukuran praktis; kecilkan ZIP (hapus build/, .dart_tool/, .git/).'); return;
    }
    setState(() {
      busy = true; terminal = false; runId = null; artifactUrl = null;
      artifactName = null; failureZipPath = null; elapsed = Duration.zero;
      startedAt = DateTime.now(); progress = 0.04; phase = 'Mengunggah source';
      status = 'Mengunggah proyek ke GitHub…'; detail = selected!.name; logs.clear();
    });
    await _saveSettings();
    ticker?.cancel();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (startedAt != null && mounted) setState(() => elapsed = DateTime.now().difference(startedAt!));
    });
    try {
      final buildId = '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9000) + 1000}';
      await _ensureWorkflow();
      final zipBytes = await source.readAsBytes();
      final inputPath = 'build-inputs/project-$buildId.zip';
      uploadedSourcePath = inputPath;
      addLog('Mengunggah ${selected!.name} (${_size(length)}) ke $repoPath/$inputPath');
      final putUri = endpoint('contents/$inputPath');
      final put = await http.put(putUri, headers: headers, body: jsonEncode({
        'message': 'Upload Flutter build source $buildId',
        'content': base64Encode(zipBytes),
        'branch': branch.text.trim().isEmpty ? 'main' : branch.text.trim(),
      })).timeout(const Duration(minutes: 3));
      if (put.statusCode < 200 || put.statusCode >= 300) {
        throw Exception('Upload source gagal (${put.statusCode}): ${_apiMessage(put.body)}');
      }
      addLog('Source terunggah. Memulai GitHub Actions…');
      if (mounted) setState(() { phase = 'Memulai workflow'; progress = 0.12; status = 'Memulai build di GitHub…'; });
      http.Response? dispatch;
      for (var attempt = 0; attempt < 3; attempt++) {
        dispatch = await http.post(
          endpoint('actions/workflows/build-flutter-apk.yml/dispatches'),
          headers: headers,
          body: jsonEncode({'ref': branch.text.trim().isEmpty ? 'main' : branch.text.trim(), 'inputs': {'source_path': inputPath, 'build_id': buildId}}),
        ).timeout(const Duration(seconds: 45));
        if (dispatch.statusCode == 204 || dispatch.statusCode == 200) break;
        if (attempt < 2 && (dispatch.statusCode == 404 || dispatch.statusCode == 422)) {
          addLog('GitHub sedang mendaftarkan workflow; mencoba lagi…');
          await Future<void>.delayed(const Duration(seconds: 4));
        } else break;
      }
      if (dispatch == null || (dispatch.statusCode != 204 && dispatch.statusCode != 200)) {
        throw Exception('Gagal menjalankan workflow (${dispatch?.statusCode}): ${_apiMessage(dispatch?.body ?? '')}. Pastikan Actions aktif dan token memiliki izin Workflows.');
      }
      addLog('Workflow dikirim. Mencari run ID…');
      if (mounted) setState(() { phase = 'Menunggu run'; progress = 0.18; status = 'Memantau Proses Di Github…'; detail = 'Workflow dikirim, sedang mencari ID build.'; });
      await _monitor(buildId);
    } catch (e) {
      addLog('ERROR: $e');
      if (mounted) setState(() { status = 'Gagal memulai build'; detail = '$e'; phase = 'Error'; terminal = true; busy = false; });
      ticker?.cancel();
    }
  }


  Future<void> _ensureWorkflow() async {
    final path = 'contents/.github/workflows/build-flutter-apk.yml';
    final existing = await http.get(endpoint(path), headers: headers).timeout(const Duration(seconds: 20));
    if (existing.statusCode == 200) {
      addLog('Workflow build-flutter-apk.yml sudah ada di repository.');
      return;
    }
    if (existing.statusCode != 404) {
      throw Exception('Tidak bisa memeriksa workflow (${existing.statusCode}): ${_apiMessage(existing.body)}');
    }
    addLog('Memasang workflow GitHub Actions ke repository…');
    final workflow = await rootBundle.loadString('assets/build-flutter-apk.yml');
    final created = await http.put(endpoint(path), headers: headers, body: jsonEncode({
      'message': 'Add Flutter APK builder workflow',
      'content': base64Encode(utf8.encode(workflow)),
      'branch': branch.text.trim().isEmpty ? 'main' : branch.text.trim(),
    })).timeout(const Duration(seconds: 30));
    if (created.statusCode < 200 || created.statusCode >= 300) {
      throw Exception('Gagal memasang workflow (${created.statusCode}): ${_apiMessage(created.body)}');
    }
    addLog('Workflow berhasil dipasang.');
  }

  Future<void> _monitor(String buildId) async {
    final started = DateTime.now();
    while (busy && !terminal && DateTime.now().difference(started) < const Duration(minutes: 90)) {
      try {
        final runsResp = await http.get(endpoint('actions/workflows/build-flutter-apk.yml/runs?per_page=20'), headers: headers).timeout(const Duration(seconds: 30));
        if (runsResp.statusCode == 401 || runsResp.statusCode == 403) throw Exception('Token tidak punya izin membaca Actions atau token tidak valid.');
        if (runsResp.statusCode != 200) throw Exception('Tidak bisa membaca daftar run (${runsResp.statusCode}): ${_apiMessage(runsResp.body)}');
        final data = jsonDecode(runsResp.body) as Map<String, dynamic>;
        final runs = (data['workflow_runs'] as List? ?? []).cast<Map<String, dynamic>>();
        Map<String, dynamic>? found;
        for (final r in runs) {
          final title = '${r['display_title'] ?? ''}';
          if (title.contains(buildId)) { found = r; break; }
        }
        if (found != null) {
          final id = '${found['id']}';
          final runStatus = '${found['status'] ?? ''}';
          final conclusion = '${found['conclusion'] ?? ''}';
          if (runId != id) { runId = id; addLog('Run ditemukan: #$id'); }
          if (mounted) setState(() {
            phase = runStatus == 'completed' ? 'Selesai' : 'Build berjalan';
            progress = runStatus == 'completed' ? 0.92 : max(progress, 0.25);
            status = runStatus == 'completed' ? (conclusion == 'success' ? 'Build berhasil!' : 'Build gagal') : 'Memantau Proses Di Github…';
            detail = runStatus == 'completed' ? 'Kesimpulan: $conclusion' : 'Status: $runStatus • Run #$id';
          });
          if (runStatus == 'completed') {
            if (conclusion == 'success') await _fetchArtifacts(id, false);
            else await _fetchArtifacts(id, true);
            await _cleanupUploadedSource();
            if (mounted) setState(() { terminal = true; busy = false; progress = 1; });
            ticker?.cancel();
            return;
          }
        } else {
          if (mounted) setState(() { status = 'Memantau Proses Di Github…'; detail = 'Menunggu GitHub membuat run'; });
        }
      } catch (e) {
        addLog('Pemantauan: $e');
        if (mounted) setState(() { detail = 'Koneksi/pemantauan terganggu: $e'; });
      }
      await Future<void>.delayed(const Duration(seconds: 8));
    }
    if (busy && !terminal) {
      if (mounted) setState(() { status = 'Pemantauan berhenti'; detail = 'Batas 90 menit tercapai. Run GitHub mungkin masih berjalan.'; busy = false; terminal = true; });
      ticker?.cancel();
      await _cleanupUploadedSource();
    }
  }

  Future<void> _cleanupUploadedSource() async {
    final path = uploadedSourcePath;
    if (path == null) return;
    try {
      final get = await http.get(endpoint('contents/$path?ref=${Uri.encodeComponent(branch.text.trim().isEmpty ? 'main' : branch.text.trim())}'), headers: headers).timeout(const Duration(seconds: 20));
      if (get.statusCode == 200) {
        final sha = '${(jsonDecode(get.body) as Map<String, dynamic>)['sha']}';
        final del = await http.delete(endpoint('contents/$path'), headers: headers, body: jsonEncode({
          'message': 'Clean up temporary Flutter build source',
          'sha': sha,
          'branch': branch.text.trim().isEmpty ? 'main' : branch.text.trim(),
        })).timeout(const Duration(seconds: 20));
        if (del.statusCode >= 200 && del.statusCode < 300) addLog('Source ZIP sementara dihapus dari repository.');
        else addLog('Catatan: source ZIP belum terhapus otomatis (${del.statusCode}).');
      }
    } catch (e) { addLog('Source ZIP cleanup gagal: $e'); }
    uploadedSourcePath = null;
  }

  Future<void> _fetchArtifacts(String id, bool failed) async {
    addLog('Mengambil artifact hasil build…');
    final res = await http.get(endpoint('actions/runs/$id/artifacts?per_page=100'), headers: headers).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) { addLog('Gagal mengambil daftar artifact: ${res.statusCode}'); return; }
    final artifacts = ((jsonDecode(res.body) as Map<String, dynamic>)['artifacts'] as List? ?? []).cast<Map<String, dynamic>>();
    Map<String, dynamic>? chosen;
    for (final a in artifacts) {
      final n = '${a['name']}';
      if (failed ? n == 'flutter-build-diagnostics' : n == 'flutter-release-apks') { chosen = a; break; }
    }
    if (chosen == null) {
      addLog(failed ? 'Artifact ZIP error belum tersedia.' : 'APK artifact tidak ditemukan.');
      if (failed && mounted) setState(() { detail = 'Build gagal. Buka run GitHub untuk melihat error; artifact diagnostik mungkin belum selesai diunggah.'; });
      return;
    }
    artifactName = '${chosen['name']}';
    artifactUrl = '${chosen['archive_download_url']}';
    if (mounted) setState(() { phase = failed ? 'Mengambil ZIP error' : 'Mengambil APK'; progress = 0.96; });
    final dl = await http.get(Uri.parse(artifactUrl!), headers: headers).timeout(const Duration(minutes: 3));
    if (dl.statusCode != 200) { addLog('Download artifact gagal: ${dl.statusCode}'); return; }
    final dir = await getApplicationDocumentsDirectory();
    final out = Directory('${dir.path}/flutter_cloud_builder');
    await out.create(recursive: true);
    final zipFile = File('${out.path}/$artifactName-$id.zip');
    await zipFile.writeAsBytes(dl.bodyBytes, flush: true);
    if (failed) {
      try {
        final outer = ZipDecoder().decodeBytes(dl.bodyBytes);
        final inner = outer.files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.zip')).toList();
        if (inner.isNotEmpty) {
          final diagnostic = File('${out.path}/flutter-build-diagnostics-$id.zip');
          await diagnostic.writeAsBytes(inner.first.content as List<int>, flush: true);
          failureZipPath = diagnostic.path;
        } else {
          failureZipPath = zipFile.path;
        }
      } catch (_) {
        failureZipPath = zipFile.path;
      }
      addLog('ZIP diagnostik disimpan: $failureZipPath');
      if (mounted) setState(() { status = 'Build gagal — ZIP error siap'; detail = 'ZIP berisi log build dan diagnostik sudah diunduh ke aplikasi.'; });
    } else {
      addLog('APK artifact ZIP berhasil diunduh. Mengekstrak APK…');
      final archive = ZipDecoder().decodeBytes(dl.bodyBytes);
      final apks = archive.files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.apk')).toList();
      for (final f in apks) {
        final safeName = f.name.split('/').last;
        final target = File('${out.path}/$safeName');
        await target.writeAsBytes(f.content as List<int>, flush: true);
      }
      if (mounted) setState(() { status = 'Build berhasil! APK siap diunduh'; detail = '${apks.length} APK ditemukan. Pilih file untuk memasang.'; progress = 1; });
    }
  }

  Future<void> _cancelBuild() async {
    final id = runId;
    if (id == null) {
      setState(() { busy = false; terminal = true; status = 'Dibatalkan'; detail = 'Build dibatalkan sebelum Run ID ditemukan. Jika GitHub sudah mulai menjalankan workflow, cek Actions untuk memastikan.'; });
      ticker?.cancel();
      return;
    }
    try {
      final r = await http.post(endpoint('actions/runs/$id/cancel'), headers: headers).timeout(const Duration(seconds: 30));
      if (r.statusCode == 202 || r.statusCode == 409) {
        addLog('Permintaan pembatalan dikirim untuk run #$id.');
        if (mounted) setState(() { busy = false; terminal = true; status = 'Build dibatalkan'; detail = 'Permintaan cancel dikirim ke GitHub Actions.'; });
      } else {
        _message('GitHub menolak pembatalan (${r.statusCode}): ${_apiMessage(r.body)}');
      }
    } catch (e) { _message('Gagal membatalkan build: $e'); }
    ticker?.cancel();
  }

  Future<List<File>> _apkFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/flutter_cloud_builder');
    if (!await d.exists()) return [];
    return d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.apk')).toList();
  }

  Future<void> _showApks() async {
    final files = await _apkFiles();
    if (!mounted) return;
    if (files.isEmpty) { _message('Belum ada APK. Jalankan build yang berhasil terlebih dahulu.'); return; }
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (ctx) => SafeArea(child: Padding(
      padding: const EdgeInsets.all(18), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('APK tersimpan', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        ...files.map((f) => ListTile(leading: const Icon(Icons.android, color: Colors.green), title: Text(f.uri.pathSegments.last), subtitle: Text(_size(f.lengthSync())), trailing: const Icon(Icons.install_mobile), onTap: () async { Navigator.pop(ctx); final result = await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive'); if (result.type != ResultType.done && mounted) _message('Tidak bisa membuka installer: ${result.message}. Izinkan instalasi aplikasi dari sumber ini di pengaturan Android.'); })),
      ]),
    )));
  }

  Future<void> _openFailureZip() async {
    if (failureZipPath == null) { _message('ZIP error belum tersedia.'); return; }
    await OpenFilex.open(failureZipPath!, type: 'application/zip');
  }

  Future<void> _testConnection() async {
    if (owner.text.trim().isEmpty || repo.text.trim().isEmpty || token.text.trim().isEmpty) { _message('Lengkapi owner, repository, dan token.'); return; }
    try {
      final r = await http.get(endpoint(''), headers: headers).timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) { await _saveSettings(); _message('GitHub terhubung ke $repoPath.'); }
      else _message('GitHub menjawab ${r.statusCode}: ${_apiMessage(r.body)}');
    } catch (e) { _message('Koneksi gagal: $e'); }
  }

  String _apiMessage(String body) {
    try { final j = jsonDecode(body); return '${j['message'] ?? body}'; } catch (_) { return body.length > 300 ? body.substring(0, 300) : body; }
  }
  String _size(int b) => b < 1024 * 1024 ? '${(b / 1024).toStringAsFixed(1)} KB' : '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  String _clock(Duration d) => '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  void _message(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Flutter Cloud Builder', style: TextStyle(fontWeight: FontWeight.bold)), actions: [IconButton(tooltip: 'Daftar APK', onPressed: _showApks, icon: const Icon(Icons.folder_open))]),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
          Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF6254D8), Color(0xFF8A72EE)]), borderRadius: BorderRadius.circular(24)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [Icon(Icons.cloud_upload_rounded, color: Colors.white, size: 38), SizedBox(width: 12), Expanded(child: Text('Build Flutter dari HP', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)))]),
            const SizedBox(height: 8), const Text('Upload source → GitHub Actions → pantau proses → download APK atau ZIP error.', style: TextStyle(color: Colors.white, height: 1.4)),
            const SizedBox(height: 16), Row(children: [const Icon(Icons.timer_outlined, color: Colors.white70), const SizedBox(width: 8), Text(_clock(elapsed), style: const TextStyle(color: Colors.white, fontSize: 26, fontFeatures: [])), const Spacer(), Text(phase, style: const TextStyle(color: Colors.white))]),
            const SizedBox(height: 10), ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: progress, minHeight: 7, backgroundColor: Colors.white24, color: Colors.white)),
          ])),
          const SizedBox(height: 18),
          _section('1', 'File proyek Flutter'),
          Card(child: ListTile(leading: const Icon(Icons.folder_zip, size: 34), title: Text(selected?.name ?? 'Pilih ZIP proyek Flutter'), subtitle: Text(selected == null ? 'Pencarian otomatis: pubspec.yaml + lib/main.dart di root atau folder bertingkat.' : '${_size(selected!.size)} • siap diunggah'), trailing: const Icon(Icons.chevron_right), onTap: busy ? null : _pickZip)),
          const SizedBox(height: 18), _section('2', 'Koneksi GitHub'),
          _field(owner, 'GitHub owner / username', 'diambil dari assets/github_config.json'),
          const SizedBox(height: 10), _field(repo, 'Nama repository', 'diambil dari assets/github_config.json'),
          const SizedBox(height: 10), _field(branch, 'Branch', 'main'),
          const SizedBox(height: 10),
          Card(child: ListTile(leading: const Icon(Icons.key), title: const Text('GitHub token dari JSON'), subtitle: Text(token.text.trim().isEmpty ? 'Belum diatur. Isi assets/github_config.json lalu build ulang APK.' : 'Token ditemukan di konfigurasi APK.'), trailing: Icon(token.text.trim().isEmpty ? Icons.warning_amber_rounded : Icons.check_circle, color: token.text.trim().isEmpty ? Colors.orange : Colors.green))),
          const SizedBox(height: 8), const Text('Owner, repository, branch, dan token dibaca dari assets/github_config.json. Token yang ditanam di APK tetap bisa diekstrak; batasi izin dan masa berlakunya.', style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 10), OutlinedButton.icon(onPressed: busy ? null : _testConnection, icon: const Icon(Icons.link), label: const Text('Tes koneksi GitHub')),
          const SizedBox(height: 18), _section('3', 'Proses build'),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 6), Text(detail),
            if (runId != null) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText('GitHub Actions Run ID: $runId')),
            const SizedBox(height: 14),
            if (busy) SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _cancelBuild, icon: const Icon(Icons.cancel_outlined), label: const Text('Batalkan build')))
            else SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _startBuild, icon: const Icon(Icons.rocket_launch), label: const Text('Mulai Build APK'))),
            if (status.contains('berhasil')) ...[
              const SizedBox(height: 10), SizedBox(width: double.infinity, child: FilledButton.tonalIcon(onPressed: _showApks, icon: const Icon(Icons.download), label: const Text('Download / Install APK'))),
            ],
            if (failureZipPath != null || status.contains('ZIP error')) ...[
              const SizedBox(height: 10), SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _openFailureZip, icon: const Icon(Icons.archive), label: const Text('Buka ZIP diagnostik error'))),
            ],
          ]))),
          const SizedBox(height: 18), _section('4', 'Log pemantauan'),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: logs.isEmpty ? const Text('Log akan muncul di sini saat proses berjalan.') : Column(crossAxisAlignment: CrossAxisAlignment.start, children: logs.take(25).map((l) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: SelectableText(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)))).toList()))),
          const SizedBox(height: 14), const Text('Catatan: build berjalan di GitHub Actions, bukan di HP. Repository harus memiliki workflow yang disertakan dalam ZIP proyek ini. APK release ditandatangani debug untuk pengujian; untuk distribusi publik gunakan signing key sendiri.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
      );

  Widget _section(String number, String title) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [Container(width: 28, height: 28, alignment: Alignment.center, decoration: const BoxDecoration(color: Color(0xFFE6E2FF), shape: BoxShape.circle), child: Text(number, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF5143BD)))), const SizedBox(width: 9), Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))]));
  Widget _field(TextEditingController c, String label, String hint) => TextField(controller: c, autocorrect: false, decoration: InputDecoration(labelText: label, hintText: hint));
}
