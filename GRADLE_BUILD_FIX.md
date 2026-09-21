# Gradle Wrapper Build Fix

- Gradle distribution: 8.14.5
- Android Gradle Plugin: 8.11.1
- Kotlin Android plugin: 2.2.20
- Java target: 17
- APK command: `flutter build apk --release --split-per-abi`

The application UI and Dart feature code are unchanged by this Gradle-only repair.
Run `./scripts/verify_gradle_wrapper.sh` before building.
