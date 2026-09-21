#!/usr/bin/env bash
set -euo pipefail

: "${CHATWITHU_BASE_URL:=http://panelbaru2.rexzystr.my.id:5201}"

flutter pub get
flutter analyze
flutter test

flutter build apk \
  --release \
  --split-per-abi \
  --dart-define="CHATWITHU_BASE_URL=${CHATWITHU_BASE_URL}"

mkdir -p dist
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk dist/ChatWithU-arm64-v8a.apk
cp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk dist/ChatWithU-armeabi-v7a.apk
cp build/app/outputs/flutter-apk/app-x86_64-release.apk dist/ChatWithU-x86_64.apk
sha256sum dist/*.apk > dist/SHA256SUMS.txt

printf '\nBuilt split-ABI APKs in dist/\n'
