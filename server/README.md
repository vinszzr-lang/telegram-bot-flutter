# ChatWithU Server • IMAGE DELIVERY FIX

Node.js + Express + Socket.IO backend for ChatWithU, prepared for Pterodactyl on port **5042**.

## Fix pada versi ini

- Foto JPG/JPEG/PNG/WEBP/GIF/HEIC/HEIF/AVIF dari Android/Google Foto diterima walaupun MIME yang dikirim Android generik.
- Foto yang dipilih di chat disimpan oleh server di `uploads/media/` sebelum pesan diteruskan ke pengirim dan penerima.
- Avatar profil disimpan oleh server di `uploads/avatars/`.
- URL foto/avatar tidak lagi otomatis dibuat sebagai `http://127.0.0.1:5201/...`.
- Jika `PUBLIC_BASE_URL` berisi domain publik, domain tersebut dipakai.
- Jika `PUBLIC_BASE_URL` kosong atau masih localhost, server otomatis memakai `X-Forwarded-Host`/`Host` dari request. Ini cocok untuk Pterodactyl/reverse proxy.
- URL media/avatar lama yang tersimpan sebagai `127.0.0.1` juga ditulis ulang ke host publik saat API mengirim data ke client.
- Target chat dan kontak/profil mendapatkan URL file yang bisa diakses melalui server yang sama.

## Pterodactyl

Environment yang direkomendasikan:

```env
PORT=5042
PUBLIC_BASE_URL=http://cloudadp.rexzystr.my.id:5042
JWT_SECRET=USE-A-LONG-RANDOM-SECRET-AT-LEAST-32-CHARS
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
```

`PUBLIC_BASE_URL` boleh dikosongkan jika reverse proxy mengirim `Host`/`X-Forwarded-Host` dengan benar.

Startup command:

```bash
npm install --omit=dev && node index.js
```

Health:

```text
http://cloudadp.rexzystr.my.id:5042/health
```

Admin:

```text
http://cloudadp.rexzystr.my.id:5042/admin
```

## Catatan penting

- Server harus dapat diakses dari HP penerima. `127.0.0.1` di HP adalah HP itu sendiri, bukan server.
- Folder `uploads/avatars` dan `uploads/media` harus tetap ada dan writable.
- Server menyimpan file yang di-upload; aplikasi client tidak perlu mengakses filesystem server secara langsung.
- Gunakan HTTPS/reverse proxy untuk produksi.
- Jangan expose `data/db.json`.


## Media relay
Foto/video disimpan sementara di `uploads/media`. Penerima mengambil media melalui `/api/media/:id/download`; setelah transfer HTTP berhasil, file relay dihapus dari server. Salinan lokal penerima tetap berada di perangkat.


## Fitur media yang didukung client

- Foto/video dikirim lewat endpoint media dan dapat diberi `caption` opsional.
- Sticker dikirim sebagai `type: sticker` dan tetap menjadi message media.
- URL media menggunakan `PUBLIC_BASE_URL`.
- Download media terautentikasi berdasarkan penerima pesan.
- Socket.IO menyediakan typing, presence, message:new, dan message:read.


## Stability & Admin enhancements
- Database writes use atomic temp-file replacement to reduce corruption risk during restarts.
- Graceful SIGTERM/SIGINT shutdown saves the database before exit.
- Added `/api/admin/health` for runtime, memory, Node, DB/upload size, and Socket.IO client metrics.
- Admin live refresh is throttled to 5 seconds and requests have a 10-second timeout.
- Admin Overview adds quick controls, database backup, user export, and server/storage/socket metrics.
- `POST /api/admin/backup` creates `data/db.json.bak`; keep the `data/` directory persistent on Pterodactyl.

## Pro build 5.0

Build ini menambahkan beberapa lapisan stabilitas dan fitur backend:

- **Idempotent message send** memakai `clientMessageId` (atau `Idempotency-Key` di client jika dipetakan ke field tersebut) agar retry HTTP tidak membuat pesan ganda.
- Rate limit untuk login/register dan pengiriman pesan/media.
- Reply metadata tetap dibawa pada teks, foto, video, sticker, dan file.
- Reactions per user: `POST /api/messages/:id/reactions` dan remove reaction dengan `DELETE`.
- Pin/unpin pesan: `POST/DELETE /api/messages/:id/pin`.
- Daftar pinned untuk chat dan grup.
- Edit pesan teks pribadi dengan `PATCH /api/chats/:username/messages/:id`.
- Polling grup tetap satu vote per akun.
- Monitoring System Live di admin panel: uptime, online users, messages 24 jam, memory, storage, Node/platform.
- Admin Command Center diperbarui dengan halaman **System Live**.

### Client contract untuk mencegah pesan dobel

Saat client mengirim pesan, buat UUID sekali untuk satu aksi kirim lalu kirim kembali UUID yang sama ketika request di-retry:

```json
{
  "message": "halo",
  "clientMessageId": "uuid-yang-sama-untuk-retry-ini"
}
```

Untuk media, sertakan `clientMessageId` sebagai multipart field. Server akan mengembalikan message yang sudah dibuat jika UUID yang sama masuk lagi dari akun yang sama.

> Jika client belum mengirim `clientMessageId`, server tetap bekerja normal, tetapi tidak dapat membedakan retry request dari dua kali klik yang memang disengaja.
