# Excellent Mirror Android

Low-latency Android screen mirroring sender.

## Build

The project uses Gradle 8.14.3 and Android Gradle Plugin 8.7.3.

For smaller APK downloads, build with:

```bash
flutter build apk --release --split-per-abi
```

Outputs:
- `app-arm64-v8a-release.apk` — most modern Android phones
- `app-armeabi-v7a-release.apk` — older 32-bit ARM phones
- `app-x86_64-release.apk` — x86_64 devices/emulators

Do not use `--android-skip-build-dependency-validation`; the project is configured to satisfy Flutter's Gradle requirement directly.
