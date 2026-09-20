# ChatWithU Android

Flutter Android client for ChatWithU.

## Package
`com.vinzz.chatwithu`

## Current update
Version `1.2.0+4`.

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
- Photo/video upload max 50 MB.
- Generic file picker is supported with a 50 MB client-side limit.
- Photo/video picking uses the native Android picker.
- Downloaded photo/video uses Gallery Saver Plus so it is saved to the device Gallery/Photos rather than the app's private files area.
- The backend media endpoint must accept `type=file` for generic-file uploads; the client now sends that type.

### Sending animation
- Text messages use an optimistic local bubble immediately.
- The local `sending` bubble is reconciled with the server message instead of being removed/re-added.
- The status icon transitions with a short animation, preventing the bubble from jumping when the 1-second poll and POST response race each other.

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
