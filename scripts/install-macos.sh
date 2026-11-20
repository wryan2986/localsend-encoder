#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${ENCODER_APPLICATIONS_DIR:-/Applications}"
if [[ ! -d "$destination" || ! -w "$destination" ]]; then
  destination="$HOME/Applications"
  mkdir -p "$destination"
fi
target="$destination/LocalSend Encoder.app"
if [[ -e "$target" || -L "$target" ]]; then
  printf 'An app already exists at %s. Quit it and move it to the Trash before reinstalling.\n' "$target" >&2
  exit 1
fi
xcrun --find swiftc >/dev/null 2>&1 || {
  echo 'Run xcode-select --install, finish Apple’s installer, then run this command again.' >&2
  exit 1
}
"$root/scripts/build-macos.sh" "$destination"
printf 'Installed. Open %s from Finder or drag it to the Dock.\n' "$target"
