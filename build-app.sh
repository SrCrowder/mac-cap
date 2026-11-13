#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "La aplicación solo se puede empaquetar en macOS." >&2
    exit 1
fi

root="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$root" -c release
bin_path="$(swift build --package-path "$root" -c release --show-bin-path)"
app="$root/build/MacCap.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_path/MacCap" "$app/Contents/MacOS/MacCap"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Aplicación creada en $app"
