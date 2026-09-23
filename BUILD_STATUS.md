# X Chat Build Notes

- App label: X Chat
- Version: 2.0.0+8
- GitHub server bootstrap remains at the existing `server.json` URL in `lib/services/api.dart`.
- The app stores the last known server locally and refreshes GitHub only at startup or after infrastructure/network failure.
- Group chat, group media, profiles, verified badge animation, notification permission, and native local notifications were added.
- Local Flutter SDK was not available in this environment, so a real `flutter analyze` / `flutter build apk` run could not be performed here.
- Server JavaScript syntax was verified with `node --check`.
