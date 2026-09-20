# Build Status

## ChatWithU v1.3.0+7

This package includes the UI/realtime fixes requested for the Android chat client:

- `flutter analyze` issue in `chat_page.dart` is fixed.
- Gallery attachment now uses one native image/video picker, with a separate Documents flow.
- Unread badges are cleared immediately when a chat is opened and remain cleared until a newer message arrives.
- Chat wallpaper is locked to the screen while the keyboard is open; the composer floats above the keyboard.
- Existing 1-second HTTP polling, optimistic sending, media upload, downloads, profile, contacts, and verified badge behavior are preserved.

The GitHub Actions workflow still runs `flutter analyze`, `flutter test`, and release APK builds.


## Pterodactyl endpoint fix
- Release CI previously compiled `CHATWITHU_BASE_URL` with an old ngrok URL. This is now fixed to `http://panelbaru2.rexzystr.my.id:5201`.
- `android:usesCleartextTraffic` is enabled because the configured endpoint is HTTP, not HTTPS.
- `lib/services/api.dart` keeps `/api/auth/login` as the login endpoint; no application feature was removed.
