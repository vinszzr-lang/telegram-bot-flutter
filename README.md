# Flutter Cloud Builder — Full JSON Config + ZIP Auto-Detect

Aplikasi Flutter Android untuk mengirim source ZIP ke GitHub dan membangun APK lewat GitHub Actions tanpa server backend tambahan.

## Fitur
- Konfigurasi GitHub di `assets/github_config.json`: owner/username, repository, branch, dan token.
- Memilih ZIP proyek Flutter dari penyimpanan Android.
- Auto-detect proyek walau struktur ZIP berbeda, misalnya:
  - `project.zip -> pubspec.yaml` dan `lib/main.dart` di root.
  - `project.zip -> nama-folder/pubspec.yaml` dan `nama-folder/lib/main.dart`.
  - `project.zip -> folder-a/folder-b/pubspec.yaml` dan `folder-a/folder-b/lib/main.dart`.
- Memasang `.github/workflows/build-flutter-apk.yml` ke repository secara otomatis jika belum ada.
- Workflow memeriksa ZIP dengan aman, mencari proyek Flutter yang valid, lalu menjalankan `flutter pub get` dan `flutter build apk --release --split-per-abi`.
- Jika file platform Android tidak ada, workflow mencoba membuat kerangka Android dengan `flutter create --platforms=android .`.
- Pantau build, timer, status, batalkan run, download APK, dan kumpulkan ZIP diagnostik ketika build gagal.

## Konfigurasi sebelum build APK aplikasi ini
Edit `assets/github_config.json`:

```json
{
  "github_owner": "USERNAME_ATAU_ORGANISASI_GITHUB",
  "github_repo": "NAMA_REPOSITORY",
  "github_branch": "main",
  "github_token": "PASTE_GITHUB_TOKEN_HERE"
}
```

Isi token dengan GitHub Personal Access Token khusus repository tersebut. Untuk fine-grained token, beri akses minimum yang diperlukan, termasuk Contents read/write, Actions read/write, dan Workflows read/write. Aktifkan GitHub Actions pada repository. Nama izin dapat berbeda sesuai jenis token dan kebijakan organisasi.

Lalu build ulang aplikasi Cloud Builder agar konfigurasi JSON ikut dibundel:

```bash
flutter pub get
flutter build apk --release
```

Owner/repository/branch dari JSON digunakan sebagai nilai awal. Kolom di aplikasi tetap bisa diedit untuk sesi berjalan.

## Cara pakai
1. Buat repository GitHub kosong atau repository khusus build, lalu aktifkan Actions.
2. Konfigurasikan `assets/github_config.json`, build APK Cloud Builder, lalu instal APK tersebut.
3. Pilih ZIP source Flutter dari HP dan tekan Mulai Build APK.
4. Pantau proses; jika berhasil, unduh APK hasil build. Jika gagal, unduh ZIP diagnostik.

## Persyaratan ZIP source
ZIP harus berisi setidaknya `pubspec.yaml` dan `lib/main.dart` di dalam satu direktori proyek yang sama. Tidak masalah bila direktori itu berada di root ZIP atau dibungkus beberapa folder. ZIP berisi APK saja bukan source Flutter dan tidak dapat dibangun ulang.

## Catatan keamanan dan batasan
- Token di JSON dalam APK dapat diekstrak oleh siapa pun yang memiliki APK. Walaupun pemakainya hanya satu orang, gunakan fine-grained token untuk satu repository, izin minimum, masa berlaku singkat, dan cabut token bila tidak dibutuhkan lagi. Cara paling aman adalah memasukkan token saat runtime atau memakai backend, bukan membundelnya.
- Source ZIP diunggah sebagai file ke repository target pada `build-inputs/`. Gunakan repository privat khusus build dan hapus file source setelah selesai jika diperlukan.
- Batas ZIP upload aplikasi: 24 MB karena menggunakan GitHub Contents API.
- Build berlangsung di runner GitHub, bukan di HP. APK release yang dihasilkan menggunakan signing debug untuk pengujian; untuk distribusi publik, atur signing release sendiri.
- Build diagnostik dapat mencakup log dan informasi proyek. Periksa isinya sebelum dibagikan.


## Mengatur token setelah APK dibuild (MT Manager)

1. Build APK Cloud Builder dengan `assets/github_config.json` berisi `github_token` kosong. Jangan commit token asli ke GitHub.
2. Setelah APK jadi, buat salinan APK dan buka/edit melalui MT Manager.
3. Masuk ke `assets/flutter_assets/assets/github_config.json` di dalam APK.
4. Isi nilai `github_token`, simpan JSON valid, lalu sign ulang APK.
5. Instal APK hasil sign ulang. Jika Android menolak update karena sertifikat berbeda, uninstall versi lama terlebih dahulu (data lokal aplikasi dapat hilang).
6. Jalankan aplikasi. Token dibaca saat aplikasi mulai; tutup paksa lalu buka kembali jika aplikasi masih berjalan saat APK diganti.

Contoh konfigurasi aman untuk commit (tanpa token):
```json
{
  "github_owner": "vinszzr-lang",
  "github_repo": "telegram-bot-flutter",
  "github_branch": "main",
  "github_token": ""
}
```

**Keamanan:** token yang ditanam di APK bukan rahasia yang aman—siapa pun yang memperoleh APK dapat mengekstraknya. Gunakan fine-grained token dengan akses hanya ke repository yang diperlukan dan masa berlaku singkat. Jangan pernah commit token asli.
