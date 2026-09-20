# ChatWithU Android

Flutter Android client for ChatWithU.

## Package
`com.vinzz.chatwithu`

## Current update
Version `1.1.0+3`.

### Realtime
- Socket.IO is the primary immediate transport.
- Client fallback sync runs every 400 ms (~2.5 requests/sec) without refreshing the page.
- Admin verified/unverified changes propagate to connected clients.
- Ban event immediately replaces the app with the banned screen.

### Profile
- Optional circular profile photo from gallery.
- Username can be changed; server migrates contacts and message history so they remain intact.
- Username collisions are rejected.

### Media
- Photo/video upload max 50 MB.
- Explicit Android media permission request.
- Downloaded media uses Gallery Saver Plus so it is saved to the device Gallery/Photos rather than the app's private files area. Gallery Saver Plus documents Gallery/Photos visibility and Android 11+ scoped-storage behavior.

### Time and chat layout
- Server UTC timestamps are converted to the device's local time.
- Day separators show `Hari Ini`, `Kemarin`, then `day month year`.
- Message bubbles resize naturally and wrap long text.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=CHATWITHU_BASE_URL=https://stock-staining-composure.ngrok-free.dev
```

APK: `build/app/outputs/flutter-apk/app-release.apk`

The release build in this project is configured for test sideloading using the runner's debug keystore. Use a private release keystore before publishing publicly.
