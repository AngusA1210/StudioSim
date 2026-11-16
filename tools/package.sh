#!/usr/bin/env bash
# What is downloaded: the app tools/export.sh made, packed for this computer's kind, with StudioSim's licence and the
# third-party notices (tools/notices.sh) beside it.
#
#   tools/package.sh
#
#   macOS    dist/StudioSim-macOS.dmg: a disk image with StudioSim.app and the Applications folder side by side, to
#            drag the one to the other. For Apple silicon alone, as the audio core is: Godot exports for both kinds of
#            Mac (its templates are made so), so its Intel half is taken off here and the app signed again as Godot
#            signed it (for this computer alone, its entitlements as they were). An Intel Mac then says plainly that
#            StudioSim isn't for it, and the download is half the size.
#   Windows  dist/StudioSim-Windows-Setup.exe: an installer (Inno Setup, tools/installer/StudioSim.iss) that puts
#            StudioSim in the user's own programs folder (no administrator's rights asked), with a Start menu entry,
#            a desktop shortcut, and an uninstaller in Settings › Apps.
#
# The release workflow (.github/workflows/release.yml) runs it for both, on GitHub's computers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$ROOT/game/project.godot")"
[ -n "$VERSION" ] || { echo "No version in game/project.godot"; exit 1; }

case "$(uname -s)" in
  Darwin)
    APP="$ROOT/dist/macOS/StudioSim.app"
    BIN="$APP/Contents/MacOS/StudioSim"
    [ -f "$BIN" ] || { echo "Make the app first: tools/export.sh"; exit 1; }
    STAGE="$ROOT/dist/macOS/disk"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    BIN="$STAGE/StudioSim.app/Contents/MacOS/StudioSim"
    if [ "$(lipo -archs "$BIN")" != "arm64" ]; then
      ENTITLEMENTS="$(mktemp)"
      codesign -d --entitlements :- "$STAGE/StudioSim.app" > "$ENTITLEMENTS" 2>/dev/null
      for lib in "$BIN" "$STAGE/StudioSim.app/Contents/Frameworks/"*.dylib; do
        if lipo -archs "$lib" | grep -qw arm64 && [ "$(lipo -archs "$lib")" != "arm64" ]; then
          lipo -thin arm64 "$lib" -output "$lib.thin" && mv "$lib.thin" "$lib"
        fi
      done
      for lib in "$STAGE/StudioSim.app/Contents/Frameworks/"*.dylib; do codesign --force --sign - "$lib"; done
      codesign --force --sign - --entitlements "$ENTITLEMENTS" "$STAGE/StudioSim.app"
      rm -f "$ENTITLEMENTS"
    fi
    codesign --verify --deep --strict "$STAGE/StudioSim.app"
    ln -s /Applications "$STAGE/Applications"
    cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
    "$ROOT/tools/notices.sh" "$STAGE/THIRD-PARTY-NOTICES.txt"
    OUT="$ROOT/dist/StudioSim-macOS.dmg"
    rm -f "$OUT"
    hdiutil create -volname "StudioSim $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
    rm -rf "$STAGE"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    APP="$ROOT/dist/Windows"
    [ -f "$APP/StudioSim.exe" ] && ls "$APP"/*.dll >/dev/null 2>&1 || { echo "Make the app first: tools/export.sh"; exit 1; }
    cp "$ROOT/LICENSE" "$APP/LICENSE.txt"
    "$ROOT/tools/notices.sh" "$APP/THIRD-PARTY-NOTICES.txt"
    ISCC=""
    for candidate in "${ISCC_PATH:-}" "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
      [ -n "$candidate" ] && [ -f "$candidate" ] && { ISCC="$candidate"; break; }
    done
    [ -n "$ISCC" ] || { echo "Inno Setup 6 isn't installed (https://jrsoftware.org/isinfo.php)"; exit 1; }
    # (MSYS2_ARG_CONV_EXCL: Git Bash leaves ISCC's /-options as they are, rather than taking them for paths)
    MSYS2_ARG_CONV_EXCL='*' "$ISCC" /Qp "/DAppVersion=$VERSION" "/DSourceDir=$(cygpath -w "$APP")" "/DOutputDir=$(cygpath -w "$ROOT/dist")" \
      "/DIconFile=$(cygpath -w "$ROOT/game/icon.ico")" "$(cygpath -w "$ROOT/tools/installer/StudioSim.iss")"
    OUT="$ROOT/dist/StudioSim-Windows-Setup.exe"
    ;;
  *) echo "StudioSim is packed on a Mac or on Windows."; exit 1 ;;
esac
[ -f "$OUT" ] || { echo "Nothing was made"; exit 1; }
echo "Made: $OUT ($(du -h "$OUT" | cut -f1))"
