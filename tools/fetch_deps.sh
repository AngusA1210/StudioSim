#!/usr/bin/env bash
# Downloads the third-party audio libraries that are too big (or binary) to keep in git.
# Safe to re-run: anything already present is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/audio_core/thirdparty"
MINIAUDIO_VERSION="0.11.25"
STEAMAUDIO_VERSION="4.8.1"
VST3SDK_TAG="v3.8.1_build_84"  # Steinberg's VST 3 SDK, MIT-licensed since 3.8
OPUS_TAG="v1.5.2"  # Xiph's Opus codec (BSD), for audio between players

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
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$tmp/steamaudio.zip" -d "$tmp"
  else  # (Windows without unzip: PowerShell's)
    powershell -NoProfile -Command "Expand-Archive -Force '$(cygpath -w "$tmp/steamaudio.zip")' '$(cygpath -w "$tmp")'"
  fi
  src="$(find "$tmp" -maxdepth 2 -type d -name include -path '*steamaudio*' | head -1)"
  src="$(dirname "$src")"
  mkdir -p "$TP/steamaudio"
  cp -R "$src/include" "$TP/steamaudio/"
  cp -R "$src/lib" "$TP/steamaudio/"
  [ -f "$src/LICENSE.md" ] && cp "$src/LICENSE.md" "$TP/steamaudio/" || true
  rm -rf "$tmp"
fi

if [ ! -f "$TP/vst3sdk/pluginterfaces/base/funknown.h" ]; then
  echo "Fetching the VST 3 SDK $VST3SDK_TAG (what a host needs of it)"
  rm -rf "$TP/vst3sdk"
  git clone -q --depth 1 --branch "$VST3SDK_TAG" https://github.com/steinbergmedia/vst3sdk.git "$TP/vst3sdk"
  git -C "$TP/vst3sdk" submodule update -q --init --depth 1 pluginterfaces public.sdk
fi

if [ ! -f "$TP/opus/include/opus.h" ]; then
  echo "Fetching Opus $OPUS_TAG"
  rm -rf "$TP/opus"
  git clone -q --depth 1 --branch "$OPUS_TAG" https://github.com/xiph/opus.git "$TP/opus"
fi

echo "Dependencies ready in $TP"
