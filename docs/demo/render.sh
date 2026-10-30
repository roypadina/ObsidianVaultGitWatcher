#!/bin/bash
# Regenerates the Obsidian Vault Git Watcher demo from scratch: compile kit + scene, render frames offscreen (no window is ever
# shown, nothing is clicked or captured, the installed app is never launched, no vault or config is read), encode.
# One command: ./render.sh
# The scene reads two of the app's real assets (Assets/icons/menubar@2x.png, AppIcon-1024.png); everything else is the kit + fake data.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$HERE}"; [ -f "$KIT/DemoKit.swift" ] || KIT="$HERE/../kit"          # repo: kit is vendored next to this file
APP="${APP_SRC:-$HERE/../..}"                                                   # repo: docs/demo -> repo root
GIF="${GIF:-$HERE/../demo.gif}"                                                 # repo: docs/demo.gif
BUILD="${BUILD:-${TMPDIR:-/tmp}/obsidian-vault-git-watcher-demo}"               # never inside the repo (hundreds of MB of frames)
mkdir -p "$BUILD"
swiftc -swift-version 5 -parse-as-library -O -o "$BUILD/demo" "$KIT/DemoKit.swift" "$HERE/scene.swift"
rm -rf "$BUILD/frames"
OVGW_ASSETS="$APP/Assets/icons" \
  "$BUILD/demo" "$BUILD/frames" 30 -AppleLocale en_US -AppleLanguages "(en)"
POSTER=${POSTER:-276}  # dialog with the message typed, badge still on (shows the app, never the empty desktop)
"$KIT/encode.sh" "$BUILD/frames" "$GIF" "${MP4:-}" "${WEBP:-}" "${POSTER:-}"
rm -rf "$BUILD/frames"                                                            # only after a successful encode (set -e)
