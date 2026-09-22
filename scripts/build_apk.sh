#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$ROOT"
flutter pub get
cd android
./gradlew --version
cd ..
flutter build apk --release --split-per-abi
