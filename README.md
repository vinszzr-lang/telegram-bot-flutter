# Excellent Mirror — Android sender

Android screen-mirroring sender designed around the same basic low-latency idea
as scrcpy: MediaProjection -> hardware H.264 -> ADB USB tunnel -> receiver.

## Default lightweight profile

- 720p maximum long edge
- 30 FPS
- 2 Mbps H.264
- hardware encoder when the device provides one
- no audio
- no unbounded frame queue
- loopback TCP only (`127.0.0.1:27183`)
- receiver uses ADB port forwarding
- display dimensions are calculated from the current phone orientation

## Build

```bash
flutter pub get
flutter build apk --release
```

The receiver is intentionally distributed as a separate ZIP.

## Important

The Android app cannot promise identical performance on every phone: encoder
hardware, USB quality, Android version and Chromebook decoding all affect the
result. The defaults are intentionally conservative to keep CPU/GPU/USB load
low while retaining a responsive stream.
