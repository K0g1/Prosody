#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$ROOT_DIR/Resources/Icon"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prosody-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
xcrun swiftc "$ROOT_DIR/script/render_icon.swift" -o "$WORK_DIR/render-icon"
mkdir -p "$WORK_DIR/Prosody.iconset"
for size in 16 32 128 256 512; do
  "$WORK_DIR/render-icon" "$ICON_DIR/Prosody.svg" "$WORK_DIR/Prosody.iconset/icon_${size}x${size}.png" "$size"
  "$WORK_DIR/render-icon" "$ICON_DIR/Prosody.svg" "$WORK_DIR/Prosody.iconset/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$WORK_DIR/Prosody.iconset" -o "$ICON_DIR/Prosody.icns"
cp "$WORK_DIR/Prosody.iconset/icon_512x512@2x.png" "$ICON_DIR/Prosody.png"
echo "Generated Prosody.icns and transparent Prosody.png from Prosody.svg"
