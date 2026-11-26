#!/bin/sh
# Regenerate the signed desktop resource from the Android collector sources.
set -eu
cd "$(dirname "$0")/.."
key=${COMPSCOPE_COLLECTOR_KEY:-$HOME/.config/compscope/collector-v2.pem}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
openssl pkey -in "$key" -pubout -outform DER -out "$work/public.der"
cmp "$work/public.der" inspector-sdk/src/main/assets/composeinspect/collector-public.der
./gradlew :collector-payload:assembleRelease -PcomposeVersion=1.10.6
apk="$PWD/collector-payload/build/outputs/apk/release/collector-payload-release-unsigned.apk"
out="$PWD/../macOS/Sources/ComposeInspectCore/Collector"
version=$(sed -n 's/^sdkVersion=//p' gradle.properties)
case "$version" in ""|*[!A-Za-z0-9.+_-]*) echo "Invalid collector version" >&2; exit 1 ;; esac
mkdir -p "$work/META-INF"
printf 'Manifest-Version: 1.0\r\nImplementation-Version: %s\r\n\r\n' "$version" > "$work/META-INF/MANIFEST.MF"
(cd "$work" && unzip -q "$apk" 'classes*.dex' && zip -Xq collector.jar META-INF/MANIFEST.MF classes*.dex)
openssl dgst -sha256 -sign "$key" -out "$work/collector.sig" "$work/collector.jar"
digest=$(shasum -a 256 "$work/collector.jar" | cut -d' ' -f1)
printf '{"version":"%s","digest":"%s"}\n' "$version" "$digest" > "$work/collector.json"
cp "$work/collector.json" "$work/collector.jar" "$work/collector.sig" "$out/"
