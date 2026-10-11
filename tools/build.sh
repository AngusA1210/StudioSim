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
  # Drive the game itself with pretend keys and clicks (silent, and it leaves saved settings alone). Godot exits
  # cleanly even if the script fails to load, so look for the line that says every check ran and passed.
  godot --headless --path "$ROOT/game" --script tests/ui_check.gd -- --silent 2>&1 | tee "$ROOT/audio_core/build/ui_check.log"
  grep -q "^ALL PASSED" "$ROOT/audio_core/build/ui_check.log" || { echo "The in-game checks did not all pass."; exit 1; }
  echo "Built. Run the game with:  godot --path \"$ROOT/game\""
else
  echo "Built. Install Godot 4.5+ (brew install --cask godot) to run the game."
fi
