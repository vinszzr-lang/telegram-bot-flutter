# Excellent Mirror Android — USB/ADB

APK sender only. Server Chromebook berada di ZIP terpisah.

APK tidak memiliki kolom IP atau port. Transport selalu ke 127.0.0.1:27183,
yang diekspos ke Chromebook memakai:

adb reverse tcp:27183 tcp:27183

Setelah USB debugging aktif dan device terlihat pada `adb devices`, buka APK,
atur resolusi/bitrate/FPS, tekan START MIRRORING, lalu buka server Chromebook
di http://localhost:3000.

Server tidak ditanam ke dalam APK.
