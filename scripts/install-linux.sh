#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null ||
   ! python3 -c 'import tkinter, venv, ensurepip; assert __import__("sys").version_info >= (3, 9)' 2>/dev/null; then
  if command -v apt-get >/dev/null && command -v sudo >/dev/null; then
    echo 'Installing missing Python and FFmpeg packages through APT…'
    apt_options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
    sudo apt-get "${apt_options[@]}" update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y --no-install-recommends python3 python3-venv python3-tk ffmpeg
  else
    echo 'Install Python 3.9+ with Tk and venv, and FFmpeg with ffprobe and libx264, then run this again.' >&2
    exit 1
  fi
fi
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -F 'libx264 ' >/dev/null; then
  echo 'Install an FFmpeg package built with libx264, then run this again.' >&2
  exit 1
fi
python3 "$root/scripts/install-desktop.py"
