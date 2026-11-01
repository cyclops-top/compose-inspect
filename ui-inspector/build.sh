#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKSPACE="$ROOT/vendor/android"
export JAVA_HOME="$WORKSPACE/prebuilts/studio/jdk/jbr25/mac-arm64/Contents/Home"
export ANDROID_HOME="$WORKSPACE/prebuilts/studio/sdk/darwin"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
cd "$WORKSPACE"
"$WORKSPACE/prebuilts/bazel/darwin-x86_64/bazel" \
  --output_user_root="$ROOT/.build/bazel" \
  --server_javabase="$JAVA_HOME" \
  build //tools/base/ui-inspector/cli:dump-ui_deploy.jar --jobs="${BUILD_JOBS:-4}" \
  --repository_cache="$ROOT/vendor/bazel-repository-cache" "$@"
mkdir -p "$ROOT/lib"
JAR_TEMP="$(mktemp "$ROOT/lib/.ui-inspector.XXXXXX")"
trap 'rm -f "$JAR_TEMP"' EXIT HUP INT TERM
cp bazel-bin/tools/base/ui-inspector/cli/dump-ui_deploy.jar "$JAR_TEMP"
chmod 644 "$JAR_TEMP"
mv -f "$JAR_TEMP" "$ROOT/lib/ui-inspector.jar"
