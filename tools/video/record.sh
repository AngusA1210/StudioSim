#!/bin/bash
# Records a demo video (tools/video/scenes/<name>.gd) from the real app, and makes its MP4: video/<name>.mp4. See
# tools/video/record.gd.
#   tools/video/record.sh <name> [video bits a second: as many as keep it under 20 MB, unless given]
set -euo pipefail
cd "$(dirname "$0")/../.."
name="${1:?give a scene: one of tools/video/scenes/}"
bitrate="${2:-auto}"
fps=30
GODOT="${GODOT:-godot}"
"$GODOT" --path game --fixed-fps "$fps" --disable-vsync --audio-driver Dummy --script ../tools/video/record.gd -- \
  --silent --offline --scene="$name" --fps="$fps"
swift tools/video/encode.swift "video/_out/$name/frames" "$fps" "video/_out/$name/sound.wav" "video/$name.mp4" "$bitrate"
