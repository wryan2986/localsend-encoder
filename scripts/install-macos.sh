#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${ENCODER_APPLICATIONS_DIR:-/Applications}"
if [[ ! -d "$destination" || ! -w "$destination" ]]; then
  destination="$HOME/Applications"
  mkdir -p "$destination"
fi
target="$destination/SpliceDesk.app"
if [[ -e "$target" || -L "$target" ]]; then
  printf 'An app already exists at %s. Quit it and move it to the Trash before reinstalling.\n' "$target" >&2
  exit 1
fi
xcrun --find swiftc >/dev/null 2>&1 || {
  echo 'Run xcode-select --install, finish Apple’s installer, then run this command again.' >&2
  exit 1
}
find_ffmpeg() {
  (command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null) ||
  for bin in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
    [[ -x "$bin/ffmpeg" && -x "$bin/ffprobe" ]] && return 0
  done
}
if ! find_ffmpeg; then
  brew_path="$(command -v brew || true)"
  if [[ -z "$brew_path" ]]; then
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [[ -x "$candidate" ]]; then brew_path="$candidate"; break; fi
    done
  fi
  if [[ -z "$brew_path" ]]; then
    echo 'SpliceDesk needs FFmpeg. Install FFmpeg and ffprobe, or install Homebrew (https://brew.sh), then try again.' >&2
    exit 1
  fi
  "$brew_path" install ffmpeg
fi
"$root/scripts/build-macos.sh" "$destination"
printf 'Installed. Open %s from Finder or drag it to the Dock.\n' "$target"
