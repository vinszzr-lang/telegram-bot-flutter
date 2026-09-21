# ChatWithU Android

Flutter Android client for ChatWithU.

## Package
`com.vinzz.chatwithu`

## Current update
Version `1.3.0+7`.

### Realtime
- Socket.IO has been removed from the Android client for a simpler and more stable connection model.
- Chat uses incremental HTTP polling every 1 second (`messages?since=...`), so new messages normally appear within about 1 second without manual refresh.
- Home/inbox sync also polls every 1 second while the home screen is active.
- Polling is protected against overlapping requests when a previous request is still running.
- HTTP 403 responses still send the user to the banned screen.

### Profile
- Optional circular profile photo from gallery.
- Username can be changed; server migrates contacts and message history so they remain intact.
- Username collisions are rejected.

### Media
- Attachment flow is now closer to WhatsApp: `Galeri` opens one native image/video picker, while `Dokumen` opens the Android document picker.
- Photo/video upload max 50 MB.
- Generic file picker is supported with a 50 MB client-side limit.
- Photo/video picking uses the native Android picker.
- Downloaded photo/video uses Gallery Saver Plus so it is saved to the device Gallery/Photos rather than the app's private files area.
- The backend media endpoint must accept `type=file` for generic-file uploads; the client now sends that type.

### Sending animation
- Text messages use an optimistic local bubble immediately.
- The local `sending` bubble is reconciled with the server message instead of being removed/re-added.
- The status icon transitions with a short animation, preventing the bubble from jumping when the 1-second poll and POST response race each other.

### Chat UI and keyboard
- The chat wallpaper is fixed to the screen and no longer jumps upward when the keyboard opens.
- The composer is overlaid above the keyboard instead of resizing/repositioning the wallpaper.
- Opening a chat immediately clears its local unread badge; a newer message received afterward can create the badge again without a manual refresh.

### Time and chat layout
- Server UTC timestamps are converted to the device's local time.
- Day separators show `Hari Ini`, `Kemarin`, then `day month year`.
- Message bubbles resize naturally and wrap long text.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=CHATWITHU_BASE_URL=http://panelbaru2.rexzystr.my.id:5201
```

APK: `build/app/outputs/flutter-apk/app-release.apk`

The release build uses the ChatWithU Pterodactyl endpoint configured by CHATWITHU_BASE_URL. It is configured for test sideloading using the runner's debug keystore. Use a private release keystore before publishing publicly.


## GitHub Actions build

The repository is intended to be uploaded with `.github/` and `pubspec.yaml` at the repository root. The workflow uses Flutter 3.47.4 / Dart 3.13.3, Java 17, Gradle 8.14, AGP 8.11.1, and Kotlin 2.2.20.


## Media upload
Composer sekarang punya tombol Foto langsung (gallery), Kamera, Video, dan File. Foto tidak lagi memakai file picker. Foto juga menampilkan preview sebelum dikirim.

## Admin dashboard
Buka `/admin` pada backend, misalnya `http://HOST:5201/admin`. Login memakai `ADMIN_USERNAME` dan `ADMIN_PASSWORD` dari environment Pterodactyl. Admin dapat mengatur Verified, badges, ban/unban, dan melihat statistik user.


## Media upload fixes
- Foto/video/file upload uses multipart form data with a 50 MB limit.
- Upload has a 120-second timeout and clearer errors.
- Server builds media URLs from the request host when `PUBLIC_BASE_URL` is not set, which works better behind a reverse proxy.
- Default admin login when no environment password is set: `admin` / `admin`.
