#!/usr/bin/env bash
set -euo pipefail

# SwiftPM produces the executable. Xcode's extractor turns the Swift
# compiler's constant values into the bundle metadata read by Shortcuts.
BIN_DIR="$1"
RESOURCES="$2"
PLIST="$3"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prosody-intents.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
EXTRACTOR="$(xcrun --find appintentsmetadataprocessor)"
VERSION="$(xcodebuild -version | awk '/Build version/ {print $3}')"
MIN_OS="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")"
BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
TRIPLE="$(uname -m)-apple-macosx$MIN_OS"
printf '%s\n' '["AppIntent","AppShortcutsProvider","AppEntity","AppEnum","EntityQuery","EntityStringQuery","DynamicOptionsProvider","IntentValueQuery","AppIntentsPackage"]' > "$WORK_DIR/protocols.json"
printf '%s\n' "$WORK_DIR/app.swiftconstvalues" > "$WORK_DIR/constvalues.list"
find Sources/ProsodyApp -name '*.swift' -print | LC_ALL=C sort > "$WORK_DIR/sources.list"

"$SWIFTC" -swift-version 6 -emit-module -whole-module-optimization -module-name ProsodyApp \
  -target "$TRIPLE" -sdk "$SDK" -I "$BIN_DIR/Modules" -F "$BIN_DIR" \
  -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
  -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK_DIR/protocols.json" \
  -emit-const-values-path "$WORK_DIR/app.swiftconstvalues" \
  -emit-module-path "$WORK_DIR/ProsodyApp.swiftmodule" "@$WORK_DIR/sources.list"

"$EXTRACTOR" --output "$RESOURCES" --toolchain-dir "$(dirname "$(dirname "$SWIFTC")")" \
  --module-name ProsodyApp --sdk-root "$SDK" --xcode-version "$VERSION" --platform-family macOS \
  --deployment-target "$MIN_OS" --target-triple "$TRIPLE" --bundle-identifier "$BUNDLE_ID" \
  --binary-file "$BIN_DIR/Prosody" --source-file-list "$WORK_DIR/sources.list" \
  --swift-const-vals-list "$WORK_DIR/constvalues.list" --compile-time-extraction --force

metadata="$RESOURCES/Metadata.appintents/extract.actionsdata"
[[ -s "$metadata" ]] && /usr/bin/grep -q 'TranscribeAudioIntent' "$metadata" || {
  echo "Shortcuts action metadata is missing from the app bundle." >&2
  exit 1
}
