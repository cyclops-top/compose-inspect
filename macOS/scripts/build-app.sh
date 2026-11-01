#!/bin/sh
set -eu

APP_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
case "$APP_CONFIGURATION" in debug|release) ;; *) echo 'BUILD_CONFIGURATION must be debug or release' >&2; exit 1 ;; esac

swift build --package-path "$APP_ROOT" --configuration "$APP_CONFIGURATION"
APP_BIN_PATH="$(swift build --package-path "$APP_ROOT" --configuration "$APP_CONFIGURATION" --show-bin-path)"
APP_BUNDLE="$APP_ROOT/dist/ComposeInspect.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_BIN_PATH/ComposeInspectLauncher" "$APP_BUNDLE/Contents/MacOS/ComposeInspect"
cp "$APP_ROOT/Configuration/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_ROOT/Configuration/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$APP_ROOT/../ui-inspector/lib/ui-inspector.jar" "$APP_BUNDLE/Contents/Resources/ui-inspector.jar"
codesign --force --sign - "$APP_BUNDLE"
printf '\nBuilt: %s\n' "$APP_BUNDLE"
