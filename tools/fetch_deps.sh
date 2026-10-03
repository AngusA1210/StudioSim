#!/usr/bin/env bash
# Downloads the third-party audio libraries that are too big (or binary) to keep in git.
# Safe to re-run: anything already present is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/audio_core/thirdparty"
MINIAUDIO_VERSION="0.11.25"
STEAMAUDIO_VERSION="4.8.1"

mkdir -p "$TP"

if [ ! -f "$TP/miniaudio/miniaudio.h" ]; then
  echo "Fetching miniaudio $MINIAUDIO_VERSION"
  mkdir -p "$TP/miniaudio"
  curl -fsSL "https://raw.githubusercontent.com/mackron/miniaudio/$MINIAUDIO_VERSION/miniaudio.h" -o "$TP/miniaudio/miniaudio.h"
fi

if [ ! -d "$TP/steamaudio/include" ]; then
  echo "Fetching Steam Audio $STEAMAUDIO_VERSION (about 170 MB)"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar "https://github.com/ValveSoftware/steam-audio/releases/download/v$STEAMAUDIO_VERSION/steamaudio_$STEAMAUDIO_VERSION.zip" -o "$tmp/steamaudio.zip"
  unzip -q "$tmp/steamaudio.zip" -d "$tmp"
  src="$(find "$tmp" -maxdepth 2 -type d -name include -path '*steamaudio*' | head -1)"
  src="$(dirname "$src")"
  mkdir -p "$TP/steamaudio"
  cp -R "$src/include" "$TP/steamaudio/"
  cp -R "$src/lib" "$TP/steamaudio/"
  [ -f "$src/LICENSE.md" ] && cp "$src/LICENSE.md" "$TP/steamaudio/" || true
  rm -rf "$tmp"
fi

echo "Dependencies ready in $TP"
