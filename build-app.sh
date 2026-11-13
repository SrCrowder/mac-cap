#!/bin/bash
# Builds build/MacCap.app (universal: Apple Silicon + Intel).
# Optional environment:
#   MACCAP_VERSION=1.2.3          version (the last number is used as the build number)
#   MACCAP_SIGN_IDENTITY=<sha1>   signing certificate; without it the app is ad-hoc signed
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

# Sparkle (automatic updates).
sparkle="$(find "$root/.build" -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' -print -quit)"
if [[ -z "$sparkle" ]]; then
    echo "No se encontró Sparkle.framework en .build" >&2
    exit 1
fi
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"

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

# Sign inside-out. Without hardened runtime: a self-signed certificate has no Team ID,
# so library validation would refuse to load Sparkle.
identity="${MACCAP_SIGN_IDENTITY:--}"
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$framework/XPCServices/Installer.xpc" "$framework/XPCServices/Downloader.xpc" \
            "$framework/Autoupdate" "$framework/Updater.app"; do
    if [[ -e "$item" ]]; then codesign --force --sign "$identity" "$item"; fi
done
codesign --force --sign "$identity" "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
echo "Aplicación creada en $app"
