# Excellent Mirror

Android screen mirroring sender dengan hardware H.264 dan receiver server terpisah.

## 1. Build Android

Project memakai:
- Android Gradle Plugin 8.11.1
- Gradle 8.13
- Java 17
- `flutter build apk --release --split-per-abi`

GitHub Actions akan mengunggah:
- `app-arm64-v8a-release.apk`
- `app-armeabi-v7a-release.apk`
- `app-x86_64-release.apk`

Jangan gunakan `--android-skip-build-dependency-validation`; konfigurasi Gradle sudah disesuaikan dengan minimum Flutter pada log build yang diberikan.

## 2. Jalankan server terpisah

Server membutuhkan Node.js 20+ dan FFmpeg.

```bash
cd server
npm install
npm start
```

Default:
- Android TCP: `27183`
- Web viewer: `8080`

Buka `http://IP-SERVER:8080/` di Chromebook/PC.

### Docker

```bash
cd server
docker build -t excellent-mirror-server .
docker run --rm -p 27183:27183 -p 8080:8080 excellent-mirror-server
```

## 3. Hubungkan Android

Di aplikasi:
- Server: IP/hostname mesin yang menjalankan server
- TCP port: `27183`
- pilih resolusi, bitrate, FPS
- tekan `START MIRRORING`
- izinkan screen capture Android

Untuk USB + ADB tanpa server LAN, jalankan di komputer:

```bash
adb reverse tcp:27183 tcp:27183
```

Lalu isi server di aplikasi dengan:

```text
127.0.0.1
```

## Low-latency behavior

Android menggunakan hardware H.264 dan tidak membuat antrean frame aplikasi. Jika receiver lambat/putus, koneksi dilepas dan dicoba lagi sehingga frame lama tidak ditumpuk.

Server memakai FFmpeg dengan mode low-delay dan membatasi `WebSocket.bufferedAmount`; viewer yang terlalu lambat diputus daripada membuat delay terus membesar.

> Tidak ada jaringan/video pipeline yang bisa menjamin "nol delay". Implementasi ini secara khusus menghindari unbounded buffering dan reconnect ke sumber secara otomatis.
