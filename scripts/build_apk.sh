#!/usr/bin/env bash
set -euo pipefail
: "${CHATWITHU_BASE_URL:=http://panelbaru2.rexzystr.my.id:5201}"
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define="CHATWITHU_BASE_URL=${CHATWITHU_BASE_URL}"
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk dist/ChatWithU.apk
sha256sum dist/ChatWithU.apk > dist/SHA256SUMS.txt
printf '\nBuilt: dist/ChatWithU.apk\n'
