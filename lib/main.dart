import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MirrorApp());

class MirrorApp extends StatefulWidget {
  const MirrorApp({super.key});

  @override
  State<MirrorApp> createState() => _MirrorAppState();
}

class _MirrorAppState extends State<MirrorApp> {
  static const _ch = MethodChannel('excellent.mirror/control');

  bool running = false;
  String status = 'Belum tersambung';

  int width = 720;
  int bitrate = 2;
  int fps = 30;
  String host = '192.168.1.100';
  int port = 27183;

  Future<void> start() async {
    final cleanHost = host.trim();
    if (cleanHost.isEmpty) {
      setState(() => status = 'Masukkan IP / hostname server.');
      return;
    }

    try {
      final result = await _ch.invokeMethod<String>('startProjection', {
        'width': width,
        'bitrate': bitrate * 1000000,
        'fps': fps,
        'host': cleanHost,
        'port': port,
      });
      if (!mounted) return;
      setState(() {
        running = true;
        status = result ?? 'Menunggu izin screen capture...';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => status = e.message ?? e.code);
    }
  }

  Future<void> stop() async {
    await _ch.invokeMethod('stopProjection');
    if (!mounted) return;
    setState(() {
      running = false;
      status = 'Berhenti';
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Excellent Mirror')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Icon(Icons.screen_share_rounded, size: 72),
            const SizedBox(height: 12),
            Text(status, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('SERVER',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      enabled: !running,
                      controller: TextEditingController(text: host)
                        ..selection = TextSelection.collapsed(offset: host.length),
                      decoration: const InputDecoration(
                        labelText: 'IP / hostname server',
                        hintText: 'contoh: 192.168.1.10',
                        prefixIcon: Icon(Icons.dns),
                      ),
                      onChanged: (v) => host = v,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      enabled: !running,
                      initialValue: '$port',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'TCP port',
                        prefixIcon: Icon(Icons.settings_ethernet),
                      ),
                      onChanged: (v) => port = int.tryParse(v) ?? 27183,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Android mengirim H.264 langsung ke server. Untuk USB/ADB, '
                      'gunakan 127.0.0.1 dan adb reverse TCP.',
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: width,
                      decoration: const InputDecoration(
                        labelText: 'Resolusi maksimum (sisi panjang)',
                      ),
                      items: const [640, 720, 900, 1080]
                          .map((v) => DropdownMenuItem(value: v, child: Text('${v}p')))
                          .toList(),
                      onChanged: running ? null : (v) => setState(() => width = v ?? 720),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: bitrate,
                      decoration: const InputDecoration(labelText: 'Bitrate'),
                      items: const [1, 2, 3, 4]
                          .map((v) => DropdownMenuItem(value: v, child: Text('$v Mbps')))
                          .toList(),
                      onChanged: running ? null : (v) => setState(() => bitrate = v ?? 2),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: fps,
                      decoration: const InputDecoration(labelText: 'FPS'),
                      items: const [24, 30, 45, 60]
                          .map((v) => DropdownMenuItem(value: v, child: Text('$v FPS')))
                          .toList(),
                      onChanged: running ? null : (v) => setState(() => fps = v ?? 30),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: running ? null : start,
              icon: const Icon(Icons.link),
              label: const Text('START MIRRORING'),
            ),
            if (running) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: stop,
                icon: const Icon(Icons.stop),
                label: const Text('STOP'),
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'Hardware H.264 • bounded buffering • no audio • '
              'reconnect otomatis • mengikuti orientasi layar.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
