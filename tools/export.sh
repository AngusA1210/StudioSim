#!/usr/bin/env bash
# The double-clickable StudioSim, for the computer this runs on: dist/macOS/StudioSim.app on a Mac, or
# dist/Windows/StudioSim.exe on Windows (in Git Bash), with what it needs beside it. Nobody running it needs Godot.
#
#   tools/export.sh
#
# It builds the audio core's extension first, for Godot's release runtime (in audio_core/build-release: the editor and
# the checks use audio_core/build's), so that what goes in is up to date. Godot's export templates must be installed
# for the Godot version used here (Editor › Manage Export Templates, once). See docs/building.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  Darwin) PRESET="macOS"; OUT="$ROOT/dist/macOS/StudioSim.app" ;;
  MINGW*|MSYS*|CYGWIN*) PRESET="Windows"; OUT="$ROOT/dist/Windows/StudioSim.exe" ;;
  *) echo "StudioSim is made into an app on a Mac or on Windows."; exit 1 ;;
esac

# Visual Studio brings its own CMake, which Git Bash doesn't see unless it is on the PATH.
if ! command -v cmake >/dev/null; then
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      VS="$("/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -latest -property installationPath 2>/dev/null | tr -d '\r' || true)"
      [ -n "$VS" ] && export PATH="$(cygpath "$VS")/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin:$PATH" ;;
  esac
fi
command -v cmake >/dev/null || { echo "CMake isn't installed (on Windows it comes with Visual Studio's C++ workload)."; exit 1; }
command -v godot >/dev/null || { echo "Godot isn't on the PATH (it is needed to make the app, though not to run it)."; exit 1; }

"$ROOT/tools/fetch_deps.sh"
BUILD="$ROOT/audio_core/build-release"
# A build folder made where the project was before it was moved (or its folder renamed) is set up again here.
CACHE="$BUILD/CMakeCache.txt"
HERE="$(cygpath -m "$ROOT" 2>/dev/null || echo "$ROOT")/audio_core"
if [ -f "$CACHE" ] && ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$HERE" "$CACHE"; then
  rm -rf "$CACHE" "$BUILD/CMakeFiles"
fi
# Godot opens the project before it exports it, with the editor's own audio core (audio_core/build's, which
# tools/build.sh makes): made here too if it isn't there, as on a computer that has only just fetched StudioSim.
case "$PRESET" in macOS) EDITOR_LIB="$ROOT/game/bin/libstudiosim_audio.dylib" ;; *) EDITOR_LIB="$ROOT/game/bin/studiosim_audio.dll" ;; esac
if [ ! -f "$EDITOR_LIB" ]; then
  cmake -S "$ROOT/audio_core" -B "$ROOT/audio_core/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$ROOT/audio_core/build" --config Release --target studiosim_audio -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
fi
cmake -S "$ROOT/audio_core" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET=template_release
cmake --build "$BUILD" --config Release --target studiosim_audio -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# Which build this is, for the title screen to say (the commit and its date; run from Godot, the game asks git itself).
STAMP="$(git -C "$ROOT" log -1 --format='%h, %cs' 2>/dev/null || true)"
[ -n "$STAMP" ] && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && STAMP="$STAMP, with changes since"
printf '## Made by tools/export.sh for the app it is making, and taken away again: which build it is (title.gd).\nconst STAMP := "%s"\n' "$STAMP" \
  > "$ROOT/game/build_info.gd"
trap 'rm -f "$ROOT/game/build_info.gd" "$ROOT/game/build_info.gd.uid"' EXIT

godot --headless --path "$ROOT/game" --import >/dev/null 2>&1 || true
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
LOG="$BUILD/export.log"
godot --headless --path "$ROOT/game" --export-release "$PRESET" "$OUT" 2>&1 | tee "$LOG"
if [ ! -e "$OUT" ] || grep -q "ERROR:" "$LOG"; then
  echo "StudioSim couldn't be made into an app (see above)."
  exit 1
fi
echo "Made: $OUT"
