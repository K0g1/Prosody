#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

die() {
  echo "package_dmg.sh: $*" >&2
  exit 1
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}

[[ "$(uname -s)" == "Darwin" ]] || die "Prosody disk images can only be created on macOS."
DIST_DIR="${PROSODY_DIST_DIR:-${CLIPPY_DIST_DIR:-$ROOT_DIR/dist}}"
[[ -d "$DIST_DIR/Prosody.app" ]] || die "Missing staged app. Run PROSODY_BUILD_CONFIGURATION=release ./script/build_and_run.sh --stage first."
DIST_DIR="$(cd "$DIST_DIR" && pwd -P)"
APP_BUNDLE="$DIST_DIR/Prosody.app"
APP_PLIST="$APP_BUNDLE/Contents/Info.plist"
SOURCE_PLIST="$ROOT_DIR/Resources/Info.plist"
NOTICES="$APP_BUNDLE/Contents/Resources/ThirdPartyNotices"

/usr/bin/plutil -lint "$SOURCE_PLIST" "$APP_PLIST" >/dev/null
for key in CFBundleIdentifier CFBundleExecutable CFBundleShortVersionString CFBundleVersion ClippyReleaseLabel LSMinimumSystemVersion; do
  expected="$(plist_value "$SOURCE_PLIST" "$key")"
  actual="$(plist_value "$APP_PLIST" "$key")"
  [[ "$actual" == "$expected" ]] || die "Staged $key is $actual; expected $expected. Stage the current release app."
done
[[ "$(plist_value "$APP_PLIST" ClippyBuildConfiguration)" == "release" ]] || die "Stage the app in release configuration before packaging."

VERSION="$(plist_value "$APP_PLIST" CFBundleShortVersionString)"
BUILD="$(plist_value "$APP_PLIST" CFBundleVersion)"
RELEASE_LABEL="$(plist_value "$APP_PLIST" ClippyReleaseLabel)"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || die "CFBundleVersion must be a positive integer."
[[ "$RELEASE_LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*)?$ && "${RELEASE_LABEL%%-*}" == "$VERSION" ]] ||
  die "ClippyReleaseLabel must match version $VERSION with an optional prerelease suffix."
[[ "${PROSODY_RELEASE_LABEL:-${CLIPPY_RELEASE_LABEL:-$RELEASE_LABEL}}" == "$RELEASE_LABEL" ]] || die "Use ClippyReleaseLabel in Resources/Info.plist to name the release."

[[ -x "$APP_BUNDLE/Contents/MacOS/Prosody" ]] || die "Missing staged executable."
[[ -x "$APP_BUNDLE/Contents/Helpers/prosody" ]] || die "Missing command-line helper."
[[ -s "$APP_BUNDLE/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || die "Missing Shortcuts metadata."
[[ -s "$APP_BUNDLE/Contents/Resources/SKILL.md" ]] || die "Missing CLI skill."
[[ -x "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" ]] || die "Missing update framework."
for key in SUFeedURL SUPublicEDKey SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
  [[ "$(plist_value "$SOURCE_PLIST" "$key")" == "$(plist_value "$APP_PLIST" "$key")" ]] || die "Staged $key differs from the release configuration."
done
[[ -f "$NOTICES/README.md" ]] || die "The staged app is missing third-party notices."
/usr/bin/diff -qr "$ROOT_DIR/Resources/ThirdPartyNotices" "$NOTICES" ||
  die "The staged notices do not match the current source."
bundled_model="$(find "$APP_BUNDLE" \( -name '*.mlmodel' -o -name '*.mlmodelc' -o -name '*.mlpackage' -o -name '*.nemo' -o -name '*.safetensors' -o -name '*.onnx' \) -print -quit)"
[[ -z "$bundled_model" ]] || die "The beta must not bundle model assets: $bundled_model"

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
signature="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
if [[ "$signature" == *"Authority=Apple Development:"* ]]; then
  die "Public packages must not use an Apple Development certificate that identifies a person."
fi
if [[ "$signature" != *"Signature=adhoc"* && "$signature" != *"Authority=Developer ID Application:"* ]]; then
  die "Use an ad-hoc or Developer ID Application signature for a public package."
fi

DMG_NAME="Prosody-$RELEASE_LABEL.dmg"
OUTPUT="$DIST_DIR/$DMG_NAME"
# Build and verify on local storage. File-provider destinations can defer
# reads of newly written payload files while hdiutil builds the filesystem.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/prosody-dmg.XXXXXX")"
PAYLOAD_DIR="$WORK_DIR/payload"
MOUNT_DIR="$WORK_DIR/mount"
IMAGE="$WORK_DIR/$DMG_NAME"
MOUNTED=0
cleanup() {
  if (( MOUNTED )); then
    /usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null || return
  fi
  rm -r -- "$WORK_DIR"
}
trap cleanup EXIT

mkdir "$PAYLOAD_DIR" "$MOUNT_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$PAYLOAD_DIR/Prosody.app"
ln -s /Applications "$PAYLOAD_DIR/Applications"
cat > "$PAYLOAD_DIR/README-FIRST-RUN.txt" <<INSTRUCTIONS
Prosody $RELEASE_LABEL (build $BUILD)

Quit the previous version, then drag Prosody to Applications and open the
installed copy. To bring over earlier Clippy or Prosody settings, choose
Settings > General > Import Preferences. Later in-app updates carry these
preferences forward.

Download this disk image only from:
https://github.com/K0g1/Prosody/releases/tag/v$RELEASE_LABEL

Verify the matching SHA-256 file before opening. This public beta is ad-hoc
signed and not notarized. If macOS blocks the first launch, select Prosody in
Finder, open the context menu, and choose Open. You can also allow it in System
Settings > Privacy & Security. Later launches use the normal menu-bar entry.

Check Settings > Dictation for Microphone and Accessibility status.
Grant Screen & System Audio Recording if you use system audio.

Prosody downloads the speech model separately after installation.

Third-party software and model notices are in
Contents/Resources/ThirdPartyNotices.
INSTRUCTIONS

/usr/bin/hdiutil create -volname "Prosody $RELEASE_LABEL" -srcfolder "$PAYLOAD_DIR" \
  -format UDZO "$IMAGE" >/dev/null
/usr/bin/hdiutil verify "$IMAGE" >/dev/null
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_DIR" "$IMAGE" >/dev/null
MOUNTED=1
/usr/bin/codesign --verify --deep --strict "$MOUNT_DIR/Prosody.app"
/usr/bin/diff -qr "$APP_BUNDLE" "$MOUNT_DIR/Prosody.app" || die "The mounted app differs from the staged app."
[[ -L "$MOUNT_DIR/Applications" && "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] ||
  die "The mounted image is missing the Applications shortcut."
/usr/bin/cmp -s "$PAYLOAD_DIR/README-FIRST-RUN.txt" "$MOUNT_DIR/README-FIRST-RUN.txt" ||
  die "The mounted image is missing the first-run instructions."
/usr/bin/hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=0

(
  cd "$WORK_DIR"
  /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
  /usr/bin/shasum -a 256 -c "$DMG_NAME.sha256" >/dev/null
)
mv -f "$IMAGE" "$OUTPUT"
mv -f "$IMAGE.sha256" "$OUTPUT.sha256"
printf '%s\n' "$OUTPUT" "$OUTPUT.sha256"
