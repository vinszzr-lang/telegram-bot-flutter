# Build Status

ChatWithU client update 1.1.0+3.

Key updates:
- Socket.IO instant message/profile/ban events.
- 400 ms fallback sync heartbeat (~2.5 requests/sec) without page refresh.
- Local timestamps converted to device time.
- Chat day separators: Hari Ini, Kemarin, then date/month/year.
- Dynamic message bubble width and wrapping.
- Gallery permission flow and GallerySaverPlus for saving media to Android Gallery.
- Optional profile photo.
- Username change preserving contacts and message history.
- Duplicate contact creation rejected by both client and server.
- Banned screen with create-new-account action.
- Verified badge changes propagate immediately.

The environment used to assemble this source does not contain the Flutter/Android SDK, so an APK was not compiled here.
