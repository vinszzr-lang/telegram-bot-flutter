#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$ROOT/android"
[ -f gradle/wrapper/gradle-wrapper.jar ] || { echo "ERROR: missing gradle-wrapper.jar" >&2; exit 1; }
[ -f gradle/wrapper/gradle-wrapper.properties ] || { echo "ERROR: missing gradle-wrapper.properties" >&2; exit 1; }
grep -q 'distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14.5-bin.zip' gradle/wrapper/gradle-wrapper.properties || { echo "ERROR: unexpected Gradle distribution" >&2; exit 1; }
./gradlew --version
