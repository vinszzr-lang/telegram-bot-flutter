#!/bin/sh
set -eu
cd "$(dirname "$0")/../android"
JAR="gradle/wrapper/gradle-wrapper.jar"
[ -f "$JAR" ] || { echo "ERROR: missing $JAR" >&2; exit 1; }
jar tf "$JAR" | grep -q '^org/gradle/wrapper/GradleWrapperMain.class$' || {
  echo "ERROR: GradleWrapperMain.class is missing from gradle-wrapper.jar" >&2; exit 1;
}
jar tf "$JAR" | grep -q '^org/gradle/wrapper/GradleWrapperMain\$StreamPath\$DeleteRuntimeException.class$' || {
  echo "ERROR: GradleWrapperMain.StreamPath.DeleteRuntimeException is missing from gradle-wrapper.jar" >&2; exit 1;
}
./gradlew --version
