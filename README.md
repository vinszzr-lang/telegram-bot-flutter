# Excellent Mirror — JavaScript Receiver

Ini adalah receiver JS untuk project Android `Excellent Mirror`.

## Yang dibutuhkan

- Node.js 18+
- ADB
- FFmpeg
- USB debugging Android aktif dan komputer sudah diizinkan
- Project Android Excellent Mirror dari ZIP Android sebelumnya

## Cara menjalankan

1. Jalankan aplikasi Android Excellent Mirror.
2. Tekan `START MIRRORING`.
3. Izinkan `Start recording or casting` / screen capture di Android.
4. Sambungkan HP ke Chromebook/PC lewat USB.
5. Di folder ZIP ini:

```bash
npm start
```

Server otomatis mencoba:

```bash
adb forward tcp:27183 tcp:27183
```

6. Buka:

```text
http://127.0.0.1:8787
```

## Kalau ADB forward gagal

Jalankan manual:

```bash
adb devices
adb forward tcp:27183 tcp:27183
npm start
```

## Alur sebenarnya

Android:
MediaProjection -> VirtualDisplay -> hardware H.264 -> TCP localhost:27183

ADB:
TCP localhost PC:27183 -> TCP localhost HP:27183

JavaScript receiver:
TCP stream -> FFmpeg -> fragmented MP4 -> browser MediaSource -> video

Jadi halaman web bukan animasi/simulasi: frame layar HP yang dikirim oleh Android benar-benar dipakai sebagai sumber video.

## Catatan

Audio belum dikirim oleh project Android ini. Receiver ini hanya menampilkan video layar.
