#!/usr/bin/env bash
# One-step build: fetch dependencies, compile the audio core and Godot extension, run the offline checks,
# and register the extension with the Godot project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
case "$CONFIG" in
  Release|Debug|RelWithDebInfo|MinSizeRel) ;;
  *) echo "Usage: tools/build.sh [Release|Debug]   (then run the game on its own: godot --path game)"; exit 1 ;;
esac

# Visual Studio brings its own CMake, which Git Bash doesn't see unless it is on the PATH.
if ! command -v cmake >/dev/null; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      VS="$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -property installationPath 2>/dev/null | tr -d '\r' || true)"
      [ -n "$VS" ] && export PATH="$(cygpath "$VS")/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin:$PATH" ;;
  esac
  command -v cmake >/dev/null || { echo "CMake isn't installed (on Windows it comes with Visual Studio's C++ workload)."; exit 1; }
fi

# One build at a time: two in the same build folder trip over each other's files (on Windows, as "being used by another
# process").
mkdir -p "$ROOT/audio_core/build"
LOCK="$ROOT/audio_core/build/.building"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another build is running here (or one was stopped part-way: if none is, delete $LOCK and try again)."
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

git -C "$ROOT" submodule update --init --recursive
"$ROOT/tools/fetch_deps.sh"
# A build folder made where the project was before it was moved (or its folder renamed) is set up again here.
CACHE="$ROOT/audio_core/build/CMakeCache.txt"
HERE="$(cygpath -m "$ROOT" 2>/dev/null || echo "$ROOT")/audio_core"
if [ -f "$CACHE" ] && ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$HERE" "$CACHE"; then
  rm -rf "$CACHE" "$ROOT/audio_core/build/CMakeFiles"
fi
cmake -S "$ROOT/audio_core" -B "$ROOT/audio_core/build" -DCMAKE_BUILD_TYPE="$CONFIG"
TARGETS="engine_tests session_server_tests studiosim_session_server studiosim_audio"
[ "$(uname -s)" = Darwin ] && TARGETS="$TARGETS plugin_panel_tests"  # (a plug-in's window and the keyboard, on a Mac)
cmake --build "$ROOT/audio_core/build" --config "$CONFIG" --target $TARGETS -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)  # (Visual Studio builds each kind in a folder of its own)
    "$ROOT/audio_core/build/$CONFIG/engine_tests.exe"
    "$ROOT/audio_core/build/$CONFIG/session_server_tests.exe" ;;
  Darwin)
    "$ROOT/audio_core/build/engine_tests"
    "$ROOT/audio_core/build/session_server_tests"
    "$ROOT/audio_core/build/plugin_panel_tests" ;;
  *)
    "$ROOT/audio_core/build/engine_tests"
    "$ROOT/audio_core/build/session_server_tests" ;;
esac

# The internet's room list (services/room-list): its SQL on SQLite, and the Worker itself, with Node or a Mac's own
# JavaScript shell.
PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] && "$PYTHON" -I "$ROOT/services/room-list/stand_in.py" --check
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
if command -v node >/dev/null; then
  node "$ROOT/services/room-list/tests.mjs"
elif [ -x "$JSC" ]; then
  "$JSC" -m "$ROOT/services/room-list/tests.mjs"
fi

# The website (website/): built, and every link in it followed, so that a heading renamed in the docs can't leave one of
# the guide's links leading nowhere.
[ -n "$PYTHON" ] && "$PYTHON" -I "$ROOT/website/build.py" --check

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
