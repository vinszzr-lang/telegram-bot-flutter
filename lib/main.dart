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
  String status = 'Siap — sambungkan USB + ADB';

  int width = 720;
  int bitrate = 4;
  int fps = 60;

  Future<void> start() async {
    try {
      final result = await _ch.invokeMethod<String>('startProjection', {
        'width': width,
        'bitrate': bitrate * 1000000,
        'fps': fps,
      });
      if (!mounted) return;
      setState(() {
        running = true;
        status = result ?? 'Mirroring dimulai';
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
        appBar: AppBar(
          title: const Text('Excellent Mirror'),
          actions: [
            Icon(running ? Icons.cast_connected : Icons.usb_rounded),
            const SizedBox(width: 16),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Icon(Icons.phone_android_rounded, size: 76),
            const SizedBox(height: 12),
            Text(status, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text(
              'USB + ADB reverse • loopback otomatis • tanpa IP/port',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('VIDEO',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<int>(
                      value: width,
                      decoration: const InputDecoration(
                        labelText: 'Resolusi maksimum',
                        prefixIcon: Icon(Icons.high_quality),
                      ),
                      items: const [540, 720, 900, 1080]
                          .map((v) => DropdownMenuItem(
                              value: v, child: Text('${v}p')))
                          .toList(),
                      onChanged: running ? null : (v) =>
                          setState(() => width = v ?? 720),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: bitrate,
                      decoration: const InputDecoration(
                        labelText: 'Bitrate',
                        prefixIcon: Icon(Icons.speed),
                      ),
                      items: const [2, 4, 6, 8, 12, 16]
                          .map((v) => DropdownMenuItem(
                              value: v, child: Text('$v Mbps')))
                          .toList(),
                      onChanged: running ? null : (v) =>
                          setState(() => bitrate = v ?? 4),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: fps,
                      decoration: const InputDecoration(
                        labelText: 'FPS',
                        prefixIcon: Icon(Icons.slow_motion_video),
                      ),
                      items: const [30, 45, 60]
                          .map((v) => DropdownMenuItem(
                              value: v, child: Text('$v FPS')))
                          .toList(),
                      onChanged: running ? null : (v) =>
                          setState(() => fps = v ?? 60),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: running ? null : start,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('START MIRRORING'),
            ),
            if (running) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: stop,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('STOP'),
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'Tidak ada antrean frame aplikasi. Pipeline dibuat untuk '
              'latensi serendah mungkin; delay absolut 0 ms tidak dapat dijamin '
              'karena encoder, USB/ADB, decoder, dan display tetap membutuhkan waktu.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
