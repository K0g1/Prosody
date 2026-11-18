#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
DIST_DIR="${PROSODY_DIST_DIR:-$ROOT_DIR/dist}"
SPARKLE_TOOLS="${PROSODY_SPARKLE_TOOLS:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin}"
KEY_ACCOUNT="${PROSODY_SPARKLE_KEY_ACCOUNT:-org.prosody.official-updates}"
PLIST="$DIST_DIR/Prosody.app/Contents/Info.plist"
LABEL="$(/usr/bin/plutil -extract ClippyReleaseLabel raw -o - "$PLIST")"
PUBLIC_KEY="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$PLIST")"
DMG="Prosody-$LABEL.dmg"

python3 script/privacy_scan.py
[[ -x "$SPARKLE_TOOLS/generate_appcast" ]] || { echo "Resolve the Sparkle package first." >&2; exit 1; }
[[ "$("$SPARKLE_TOOLS/generate_keys" --account "$KEY_ACCOUNT" -p)" == "$PUBLIC_KEY" ]] ||
  { echo "The signing account must match the public key in the staged build." >&2; exit 1; }
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 -c "$DMG.sha256"
)

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/prosody-appcast.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
/usr/bin/ditto "$DIST_DIR/$DMG" "$work_dir/$DMG"
install -m 644 "docs/releases/v$LABEL.md" "$work_dir/Prosody-$LABEL.md"
"$SPARKLE_TOOLS/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --link "https://github.com/K0g1/Prosody/releases/tag/v$LABEL" \
  --download-url-prefix "https://github.com/K0g1/Prosody/releases/download/v$LABEL/" \
  -o "$work_dir/appcast.xml" "$work_dir"
"$SPARKLE_TOOLS/sign_update" --account "$KEY_ACCOUNT" --verify "$work_dir/appcast.xml"
install -m 644 "$work_dir/appcast.xml" "$DIST_DIR/appcast.xml"
