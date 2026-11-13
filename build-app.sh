#!/bin/bash
# Builds build/MacCap.app (universal: Apple Silicon + Intel), ad-hoc signed.
# Optional: MACCAP_VERSION=1.2.3 ./build-app.sh
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "La aplicación solo se puede compilar en macOS." >&2
    exit 1
fi

root="$(cd "$(dirname "$0")" && pwd)"
arch_flags=(--arch arm64 --arch x86_64)
if [[ "${MACCAP_NATIVE_ONLY:-0}" == "1" ]]; then arch_flags=(); fi

swift build --package-path "$root" -c release "${arch_flags[@]}"
bin_path="$(swift build --package-path "$root" -c release "${arch_flags[@]}" --show-bin-path)"

app="$root/build/MacCap.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/MacCap" "$app/Contents/MacOS/MacCap"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"

# App icon (.icns) from the 1024 px PNG.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

if [[ -n "${MACCAP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MACCAP_VERSION" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${MACCAP_VERSION##*.}" "$app/Contents/Info.plist"
fi

codesign --force --sign - "$app"
echo "Aplicación creada en $app"
