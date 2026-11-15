#!/usr/bin/env bash
# THIRD-PARTY-NOTICES.txt: StudioSim's licence and its additional permission, then the licence of everything the app is
# built with or carries (Godot and what is built into it, godot-cpp, Steam Audio and what is built into that, miniaudio,
# the VST 3 SDK, Opus), as their licences ask. It goes with the app, in each installer (tools/package.sh).
#
#   tools/notices.sh <file to write>
#
# Needs Godot on the PATH (it reports its own), and tools/fetch_deps.sh to have run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TP="$ROOT/audio_core/thirdparty"
OUT="${1:?usage: tools/notices.sh <file to write>}"
GODOT="${GODOT:-godot}"

section() {  # a heading, then a file's text
  printf '\n\n==============================================================================\n%s\n==============================================================================\n\n' "$1"
  tr -d '\r' < "$2"
}

for needed in "$TP/godot-cpp/LICENSE.md" "$TP/steamaudio/LICENSE.md" "$TP/steamaudio/THIRDPARTY.md" "$TP/miniaudio/miniaudio.h" \
              "$TP/vst3sdk/LICENSE.txt" "$TP/opus/COPYING" "$ROOT/LICENSE"; do
  [ -f "$needed" ] || { echo "Missing $needed (run tools/fetch_deps.sh)"; exit 1; }
done

godot_text="$(mktemp)"
trap 'rm -f "$godot_text" "$godot_text.mini"' EXIT
"$GODOT" --headless --path "$ROOT/game" --script "$ROOT/tools/godot_licenses.gd" 2>/dev/null |
  awk '/^@@NOTICES@@$/ {on = 1; next} /^@@END@@$/ {on = 0} on' > "$godot_text"
[ -s "$godot_text" ] || { echo "Godot didn't report its licences"; exit 1; }
# miniaudio's licence is at the end of its one file.
awk '/^This software is available as a choice of the following licenses/ {on = 1} on' "$TP/miniaudio/miniaudio.h" |
  sed -e 's#^\*/$##' > "$godot_text.mini"

{
  cat <<'HEAD'
StudioSim
Copyright (C) 2026 Andrew Angus

StudioSim is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
License, version 3, as published by the Free Software Foundation. It is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See the GNU General Public License (the LICENSE file, which comes with it) for more details. Its source
code is at https://github.com/AngusA1210/StudioSim.

Additional permission under GNU GPL version 3 section 7: if you modify this Program, or any covered work, by linking
or combining it with Steam Audio (or a modified version of it), containing parts covered by the terms of its licences
(among them the Intel Simplified Software License), or with Steinberg's ASIO SDK under Steinberg's proprietary
licence, the licensors of this Program grant you additional permission to convey the resulting work. Corresponding
Source for a non-source form of such a combination need not include the source code of those libraries.

The rest of this file is the licences of what StudioSim is built with, and carries.
HEAD
  section "Godot Engine (https://godotengine.org)" "$godot_text"
  section "godot-cpp (https://github.com/godotengine/godot-cpp)" "$TP/godot-cpp/LICENSE.md"
  section "Steam Audio (https://github.com/ValveSoftware/steam-audio)" "$TP/steamaudio/LICENSE.md"
  section "What Steam Audio is built with" "$TP/steamaudio/THIRDPARTY.md"
  section "miniaudio (https://github.com/mackron/miniaudio)" "$godot_text.mini"
  section "VST 3 SDK (https://github.com/steinbergmedia/vst3sdk). VST is a registered trademark of Steinberg Media Technologies GmbH." "$TP/vst3sdk/LICENSE.txt"
  section "Opus (https://opus-codec.org)" "$TP/opus/COPYING"
  printf '\n'
} > "$OUT"
echo "Wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
