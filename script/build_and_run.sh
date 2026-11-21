#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION="${PROSODY_BUILD_CONFIGURATION:-${CLIPPY_BUILD_CONFIGURATION:-debug}}"
# TCC permissions are keyed to the bundle identifier and the designated code
# requirement. Ad-hoc signing changes that requirement after every rebuild,
# which makes macOS keep showing an app as enabled while rejecting the newly
# built binary. Prefer the user's stable Apple Development identity; callers
# can still opt into an explicit identity or ad-hoc signing with `-`.
SIGNING_IDENTITY="${PROSODY_SIGNING_IDENTITY:-${CLIPPY_SIGNING_IDENTITY:-}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | awk -F '"' '$2 ~ /^Apple Development:/ && !found { print $2; found = 1 }')"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
  fi
fi
if [[ "$MODE" == "--release" ]]; then CONFIGURATION="release"; MODE="run"; fi
REQUEST_PERMISSIONS=0
if [[ "$MODE" == "--request-permissions" || "$MODE" == "request-permissions" ]]; then
  REQUEST_PERMISSIONS=1
  MODE="--verify"
fi
APP_NAME="Prosody"
BUNDLE_ID="com.openai.clippy"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
DIST_DIR="${PROSODY_DIST_DIR:-${CLIPPY_DIST_DIR:-$ROOT_DIR/dist}}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Resources/Prosody.entitlements"
APP_ICON="$ROOT_DIR/Resources/Icon/Prosody.icns"
THIRD_PARTY_NOTICES="$ROOT_DIR/Resources/ThirdPartyNotices"

die() {
  echo "build_and_run.sh: $*" >&2
  exit 1
}

kill_running_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app_bundle() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Prosody requires macOS; found $(uname -s)."
  [[ -f "$INFO_PLIST" ]] || die "Missing packaging resource: $INFO_PLIST"
  [[ -f "$ENTITLEMENTS" ]] || die "Missing entitlements resource: $ENTITLEMENTS"

  [[ -f "$THIRD_PARTY_NOTICES/README.md" ]] || die "Missing third-party notices: $THIRD_PARTY_NOTICES"

  # Rebuild the icon only when its editable SVG or renderer changes.
  if [[ ! -f "$APP_ICON" || "$ROOT_DIR/Resources/Icon/Prosody.svg" -nt "$APP_ICON" || "$ROOT_DIR/script/render_icon.swift" -nt "$APP_ICON" || "$ROOT_DIR/script/build_icon.sh" -nt "$APP_ICON" ]]; then
    "$ROOT_DIR/script/build_icon.sh"
  fi

  # SwiftPM builds both products. The bundle stage also uses Xcode’s App Intents extractor.
  local build_args=(--force-resolved-versions --configuration "$CONFIGURATION")
  if [[ "$CONFIGURATION" == "release" ]]; then
    build_args+=(
      -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR/.build=/__PROSODY_BUILD__"
      -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR/.build=/__PROSODY_BUILD__"
      -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=/__PROSODY_SOURCE__"
      -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=/__PROSODY_SOURCE__"
      -Xswiftc -file-compilation-dir -Xswiftc "/__PROSODY_SOURCE__"
      -Xcc "-ffile-prefix-map=$ROOT_DIR/.build=/__PROSODY_BUILD__"
      -Xcc "-fdebug-prefix-map=$ROOT_DIR/.build=/__PROSODY_BUILD__"
      -Xcc "-ffile-prefix-map=$ROOT_DIR=/__PROSODY_SOURCE__"
      -Xcc "-fdebug-prefix-map=$ROOT_DIR=/__PROSODY_SOURCE__"
      -Xcc "-fmacro-prefix-map=$ROOT_DIR=/__PROSODY_SOURCE__"
      -Xlinker -oso_prefix -Xlinker "$ROOT_DIR/.build"
    )
  fi
  swift build "${build_args[@]}" --product "$APP_NAME"
  swift build "${build_args[@]}" --product ProsodyCLI
  local build_bin_path
  build_bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
  local build_binary="$build_bin_path/$APP_NAME"
  [[ -x "$build_binary" ]] || die "SwiftPM did not produce $build_binary"
  local sparkle_artifact="$build_bin_path/Sparkle.framework"
  [[ -d "$sparkle_artifact" ]] || die "SwiftPM did not resolve Sparkle.framework"

  # This is a script-owned artifact, so it is safe to replace on each run.
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_CONTENTS/Helpers" "$APP_CONTENTS/Frameworks"
  install -m 755 "$build_binary" "$APP_BINARY"
  local sparkle="$APP_CONTENTS/Frameworks/Sparkle.framework"
  /usr/bin/ditto "$sparkle_artifact" "$sparkle"
  local bundle_rpath="@executable_path/../Frameworks"
  if ! /usr/bin/otool -l "$APP_BINARY" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -Fxq "$bundle_rpath"; then
    /usr/bin/install_name_tool -add_rpath "$bundle_rpath" "$APP_BINARY"
  fi
  install -m 755 "$build_bin_path/ProsodyCLI" "$APP_CONTENTS/Helpers/prosody"
  install -m 644 "$ROOT_DIR/docs/skills/prosody-cli/SKILL.md" "$APP_RESOURCES/SKILL.md"
  install -m 644 "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
  install -m 644 "$APP_ICON" "$APP_RESOURCES/Prosody.icns"
  install -m 644 "$ROOT_DIR/Sources/ProsodyCore/Resources/ProsodyMenuBar.svg" "$APP_RESOURCES/ProsodyMenuBar.svg"
  /usr/bin/ditto "$THIRD_PARTY_NOTICES" "$APP_RESOURCES/ThirdPartyNotices"

  # Stage only the current package resource bundle. The shared .build tree can
  # contain stale bundles from an earlier product name; never copy those.
  local resource_bundle="$build_bin_path/Prosody_ProsodyCore.bundle"
  [[ -d "$resource_bundle" ]] || die "SwiftPM did not produce $resource_bundle"
  cp -R "$resource_bundle" "$APP_RESOURCES/"

  /usr/bin/plutil -replace LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$APP_CONTENTS/Info.plist"
  /usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_CONTENTS/Info.plist"
  /usr/bin/plutil -replace CFBundleExecutable -string "$APP_NAME" "$APP_CONTENTS/Info.plist"
  /usr/bin/plutil -replace CFBundleIconFile -string "Prosody.icns" "$APP_CONTENTS/Info.plist"
  /usr/bin/plutil -insert ClippyBuildConfiguration -string "$CONFIGURATION" "$APP_CONTENTS/Info.plist"
  /usr/bin/plutil -lint "$APP_CONTENTS/Info.plist" >/dev/null

  local staged_identifier
  staged_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_CONTENTS/Info.plist")"
  [[ "$staged_identifier" == "$BUNDLE_ID" ]] || die "Bundle identifier mismatch: expected $BUNDLE_ID, found $staged_identifier"

  "$ROOT_DIR/script/extract_app_intents.sh" "$build_bin_path" "$APP_RESOURCES" "$APP_CONTENTS/Info.plist"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_CONTENTS/Helpers/prosody"

  # A stable development identity keeps TCC grants valid across rebuilds. It
  # must be explicit: changing the signer of an existing sandbox installation
  # can trigger a separate macOS container-ownership approval.
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing requested: macOS may require removing and re-adding Prosody in Screen & System Audio Recording after rebuilds." >&2
  else
    echo "Signing with a stable identity" >&2
    local sparkle_version="$sparkle/Versions/$(readlink "$sparkle/Versions/Current")"
    for component in "$sparkle_version/XPCServices/"*.xpc "$sparkle_version/Autoupdate" "$sparkle_version/Updater.app" "$sparkle_version"; do
      /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --preserve-metadata=identifier,entitlements,flags "$component"
    done
  fi
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

  local signed_identifier
  signed_identifier="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | sed -n 's/^Identifier=//p')"
  [[ "$signed_identifier" == "$BUNDLE_ID" ]] || die "Signed bundle identifier mismatch: expected $BUNDLE_ID, found $signed_identifier"
}

open_app() {
  [[ -d "$APP_BUNDLE" ]] || die "App bundle was not staged: $APP_BUNDLE"
  # LaunchServices does not reliably forward test environment values. Pass
  # explicit arguments while still launching the staged app bundle. A normal
  # launch stays in the menu bar; only --show-controls opens the QA recorder.
  local app_args=()
  local demo_mode="${PROSODY_DEMO_MODE:-${CLIPPY_DEMO_MODE:-0}}"
  local dictation_fixture="${PROSODY_DICTATION_FIXTURE:-${CLIPPY_DICTATION_FIXTURE:-0}}"
  local show_controls="${PROSODY_SHOW_CONTROLS:-${CLIPPY_SHOW_CONTROLS:-0}}"
  if [[ "$demo_mode" == "1" ]]; then
    app_args+=(--demo)
    if [[ "$dictation_fixture" == "1" ]]; then
      app_args+=(--dictation-fixture)
    fi
  fi
  if [[ "$REQUEST_PERMISSIONS" == "1" ]]; then
    app_args+=(--request-permissions)
  fi
  if [[ "$show_controls" == "1" ]]; then
    app_args+=(--show-controls)
  fi
  if (( ${#app_args[@]} > 0 )); then
    /usr/bin/open -n "$APP_BUNDLE" --args "${app_args[@]}"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  --stage)
    build_app_bundle
    echo "Staged $APP_BUNDLE"
    ;;
  run|--run)
    kill_running_app
    build_app_bundle
    open_app
    echo "Launched $APP_BUNDLE"
    ;;
  --debug|debug)
    kill_running_app
    build_app_bundle
    exec /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    kill_running_app
    build_app_bundle
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    kill_running_app
    build_app_bundle
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    kill_running_app
    build_app_bundle
    open_app
    for _ in {1..10}; do
      if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "Verified $APP_NAME ($CONFIGURATION) is running from $APP_BUNDLE"
        exit 0
      fi
      sleep 0.2
    done
    echo "build_and_run.sh: app bundle opened, but $APP_NAME was not running after 2 seconds" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--release|--stage|--debug|--logs|--telemetry|--verify|--request-permissions]" >&2
    exit 2
    ;;
esac
