#!/bin/sh
set -eu
APP_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swift "$APP_ROOT/scripts/render-app-icon.swift" "$APP_ROOT/Artwork/AppIcon.svg" "$ICON_WORK/render.png"
sips -z 1024 1024 "$ICON_WORK/render.png" --out "$APP_ROOT/Artwork/AppIcon.png" >/dev/null
mkdir -p "$ICON_WORK/AppIcon.iconset"
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" "$APP_ROOT/Artwork/AppIcon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    ICON_RETINA=$((ICON_SIZE * 2))
    sips -z "$ICON_RETINA" "$ICON_RETINA" "$APP_ROOT/Artwork/AppIcon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP_ROOT/Configuration/AppIcon.icns"
