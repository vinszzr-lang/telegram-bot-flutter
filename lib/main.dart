import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MirrorApp());

class MirrorApp extends StatefulWidget {
  const MirrorApp({super.key});

  @override
  State<MirrorApp> createState() => _MirrorAppState();
}

class _MirrorAppState extends State<MirrorApp> {
  static const ch = MethodChannel('excellent.mirror/control');

  Timer? timer;
  String status = 'Siap — tekan START untuk terhubung ke server';
  bool running = false;

  int width = 720;
  int bitrate = 4;
  int fps = 30;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => refresh(),
    );
    refresh();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final s = await ch.invokeMethod<String>('status');
      if (!mounted || s == null) return;

      setState(() {
        status = s;
        running = s != 'Berhenti' &&
            !s.startsWith('ERROR') &&
            !s.startsWith('Izin screen capture dibatalkan') &&
            s != 'Siap — tekan START untuk terhubung ke server';
      });
    } catch (_) {
      // Native side may not be ready yet.
    }
  }

  Future<void> start() async {
    try {
      final s = await ch.invokeMethod<String>(
        'startProjection',
        {
          'width': width,
          'bitrate': bitrate * 1000000,
          'fps': fps,
        },
      );

      if (!mounted) return;

      setState(() {
        status = s ?? 'Meminta izin screen capture...';
        running = false;
      });

      await refresh();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        status = e.message ?? e.code;
        running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = 'ERROR: $e';
        running = false;
      });
    }
  }

  Future<void> stop() async {
    try {
      await ch.invokeMethod('stopProjection');
    } catch (_) {
      // Ignore stop errors when the native service is already stopped.
    }

    if (!mounted) return;

    setState(() {
      running = false;
      status = 'Berhenti';
    });
  }

  Widget drop(
    String label,
    int value,
    List<int> vals,
    ValueChanged<int?> on,
  ) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: vals
          .map(
            (v) => DropdownMenuItem<int>(
              value: v,
              child: Text(
                label == 'Bitrate'
                    ? '$v Mbps'
                    : label == 'FPS'
                        ? '$v FPS'
                        : '${v}p',
              ),
            ),
          )
          .toList(),
      onChanged: running ? null : on,
    );
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
            Icon(
              running ? Icons.cast_connected : Icons.usb_rounded,
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Icon(
              Icons.phone_android_rounded,
              size: 76,
            ),
            const SizedBox(height: 12),
            Text(
              status,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Internet • GitHub server.json • Pterodactyl Node.js',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'VIDEO',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 14),
                    drop(
                      'Resolusi maksimum',
                      width,
                      [540, 720, 900, 1080],
                      (v) => setState(() => width = v ?? 720),
                    ),
                    const SizedBox(height: 12),
                    drop(
                      'Bitrate',
                      bitrate,
                      [2, 4, 6, 8, 12, 16],
                      (v) => setState(() => bitrate = v ?? 4),
                    ),
                    const SizedBox(height: 12),
                    drop(
                      'FPS',
                      fps,
                      [30, 45, 60],
                      (v) => setState(() => fps = v ?? 60),
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
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: running ? stop : null,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('STOP'),
            ),
            const SizedBox(height: 18),
            const Text(
              'Urutan: izinkan screen capture → encoder H.264 → '
              'ambil server dari GitHub → WebSocket langsung ke server. '
              'Jika server timeout, konfigurasi GitHub dicek lagi otomatis.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
