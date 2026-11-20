#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:-$root/dist}"
arch="${ENCODER_MAC_ARCH:-$(uname -m)}"
case "$arch" in
  arm64|x86_64|universal) ;;
  *) echo "Unsupported build architecture: $arch" >&2; exit 1 ;;
esac
command -v xcrun >/dev/null
xcrun --find swiftc >/dev/null || { echo 'Install Apple’s Xcode Command Line Tools first.' >&2; exit 1; }

mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
build="$(mktemp -d "$destination/.encoder-build.XXXXXXXX")"
trap 'rm -rf -- "$build"' EXIT
app="$build/LocalSend Encoder.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/macos/Info.plist" "$app/Contents/"
cp "$root/assets/AppIcon.icns" "$app/Contents/Resources/LocalSendEncoder.icns"
binary="$app/Contents/MacOS/LocalSend Encoder"

compile() {
  xcrun swiftc -O -swift-version 5 -target "$1-apple-macos14.0" \
    -module-cache-path "$build/module-cache" "$root/macos/main.swift" -o "$2"
}
if [[ "$arch" == universal ]]; then
  compile arm64 "$build/arm64"
  compile x86_64 "$build/x86_64"
  xcrun lipo -create "$build/arm64" "$build/x86_64" -output "$binary"
else
  compile "$arch" "$binary"
fi
codesign --force --sign - "$app"
codesign --verify --strict "$app"
final="$destination/LocalSend Encoder.app"
if [[ -e "$final" || -L "$final" ]]; then
  echo "Build destination already exists: $final" >&2
  exit 1
fi
mv "$app" "$final"
printf 'Built %s\n' "$final"
