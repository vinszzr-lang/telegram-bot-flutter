# Build Status

ChatWithU client update 1.2.0+4.

Key updates:
- Removed Socket.IO from the Flutter client.
- Chat incremental polling every 1 second using `messages?since=`.
- Home/inbox polling every 1 second while Home is visible.
- Optimistic text sending with stable reconciliation and animated send status.
- Added generic file picker support with a 50 MB client-side limit.
- Photo/video upload remains limited to 50 MB.
- Local timestamps converted to device time.
- Chat day separators: Hari Ini, Kemarin, then date/month/year.
- Dynamic message bubble width and wrapping.
- Gallery Saver Plus for saving photo/video media.
- Optional profile photo.
- Username change preserving contacts and message history.
- Banned screen on HTTP 403.

The environment used to assemble this source does not contain the Flutter/Android SDK, so an APK was not compiled here. The GitHub Actions workflow now uses Flutter 3.47.4 (Dart 3.13.3) for the build.
