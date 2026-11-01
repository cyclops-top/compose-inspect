#!/bin/zsh
set -e
cd /Users/justin/.local/share/ui-inspector/source
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME=/Users/justin/Library/Android/sdk
exec prebuilts/bazel/darwin-x86_64/bazel --server_javabase="$JAVA_HOME" build //tools/base/ui-inspector/cli:dump-ui --jobs=4 "$@"
