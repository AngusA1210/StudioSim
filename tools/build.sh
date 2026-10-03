#!/usr/bin/env bash
# One-step build: fetch dependencies, compile the audio core and Godot extension, run the offline checks,
# and register the extension with the Godot project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"

git -C "$ROOT" submodule update --init --recursive
"$ROOT/tools/fetch_deps.sh"
cmake -S "$ROOT/audio_core" -B "$ROOT/audio_core/build" -DCMAKE_BUILD_TYPE="$CONFIG"
cmake --build "$ROOT/audio_core/build" --target engine_tests soundroom_audio -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
"$ROOT/audio_core/build/engine_tests"

if command -v godot >/dev/null; then
  godot --headless --path "$ROOT/game" --import >/dev/null 2>&1 || true
  echo "Built. Run the game with:  godot --path \"$ROOT/game\""
else
  echo "Built. Install Godot 4.5+ (brew install --cask godot) to run the game."
fi
