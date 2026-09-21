# ChatWithU build status

## READY_BUILD_V2
- Flutter Android project configured for Flutter 3.47.4 / Java 17 / AGP 8.11.1 / Kotlin 2.2.20.
- Kotlin compiler uses `compilerOptions.jvmTarget = JVM_17`.
- Media composer has direct Photo, Video, Camera, and File actions.
- Photo selection uses `image_picker` directly and shows a preview before upload.
- Android CAMERA permission added for camera capture.
- Backend validates image/video MIME types.
- Admin dashboard available at `/admin`; verified, badges, ban/unban are supported.
- GitHub Actions keeps release split-ABI build and ignores informational analyzer lints.

## Validation
- `node --check server/index.js`: PASS.
- ZIP structure/integrity: PASS.
- Flutter/Dart compile could not be executed in this environment because Flutter SDK is not installed.


## Realtime refresh update
- Home sync polling: every 1 second.
- Chat message sync polling: every 1 second.
- Profile sync polling: every 1 second.
- Socket.IO remains enabled for immediate message/typing/profile events; 1-second polling acts as a fallback so verified badges and other server-side changes appear without manual refresh.
