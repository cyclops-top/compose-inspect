#!/bin/sh
set -eu

APP_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
APP_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
case "$APP_CONFIGURATION" in debug|release) ;; *) echo 'BUILD_CONFIGURATION must be debug or release' >&2; exit 1 ;; esac

swift build --package-path "$APP_ROOT" --configuration "$APP_CONFIGURATION"
APP_BIN_PATH="$(swift build --package-path "$APP_ROOT" --configuration "$APP_CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_ROOT/dist"
BUILD_DIR="$(mktemp -d "$APP_ROOT/dist/.bundle-XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP_BUNDLE="$BUILD_DIR/CompScope.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_BIN_PATH/ComposeInspectLauncher" "$APP_BUNDLE/Contents/MacOS/CompScope"
cp "$APP_ROOT/Configuration/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_ROOT/Configuration/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
if [ -e "$APP_ROOT/dist/CompScope.app" ]; then
    mv "$APP_ROOT/dist/CompScope.app" "$BUILD_DIR/previous.app"
fi
if ! mv "$APP_BUNDLE" "$APP_ROOT/dist/CompScope.app"; then
    if [ -e "$BUILD_DIR/previous.app" ]; then mv "$BUILD_DIR/previous.app" "$APP_ROOT/dist/CompScope.app"; fi
    exit 1
fi
printf '\nBuilt: %s\n' "$APP_ROOT/dist/CompScope.app"
