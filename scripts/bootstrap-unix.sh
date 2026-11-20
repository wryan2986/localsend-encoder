#!/usr/bin/env bash
set -euo pipefail

archive="${1:?Pass the HTTPS source archive URL for the release tag.}"
case "$archive" in https://*) ;; *) echo 'Use an HTTPS source archive URL.' >&2; exit 1 ;; esac
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
curl --proto '=https' --proto-redir '=https' -fsSL "$archive" -o "$temp/source.tar.gz"
tar -xzf "$temp/source.tar.gz" -C "$temp" --strip-components 1
case "$(uname -s)" in
  Darwin) bash "$temp/scripts/install-macos.sh" ;;
  Linux) bash "$temp/scripts/install-linux.sh" ;;
  *) echo 'This installer supports macOS and Linux.' >&2; exit 1 ;;
esac
