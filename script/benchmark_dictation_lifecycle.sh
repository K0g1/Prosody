#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/benchmark_dictation_lifecycle.sh [options]

Generates a short local speech fixture and measures the candidate dictation
model lifecycle with the installed Parakeet Unified model. No microphone, UI,
clipboard, history, or paste path is used.

  --retention SECONDS   Repeatable idle-retention trial (default: 20)
  --baseline-loader     Also run a direct StreamingUnifiedAsrManager control
  --skip-fake-checks    Skip deterministic cancellation/TTL checks
  --show-text           Print generated-fixture transcripts
  --binary PATH         Run this ProsodyValidation binary instead of swift run
  --fixtures-only       Generate and hash the fixture without loading a model
  -h, --help            Show this help
EOF
}

die() { echo "benchmark_dictation_lifecycle.sh: $*" >&2; exit 1; }
retentions=()
baseline_loader=0
skip_fake=0
show_text=0
binary=
fixtures_only=0
while (( $# > 0 )); do
  case "$1" in
    --retention)
      shift
      [[ ${1:-} =~ ^([0-9]+([.][0-9]+)?)$ ]] || die "--retention requires seconds."
      retentions+=("$1")
      ;;
    --baseline-loader) baseline_loader=1 ;;
    --skip-fake-checks) skip_fake=1 ;;
    --show-text) show_text=1 ;;
    --binary)
      shift
      [[ -n ${1:-} ]] || die "--binary requires a path."
      binary=$1
      ;;
    --fixtures-only) fixtures_only=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done
(( ${#retentions[@]} > 0 )) || retentions=(20)

[[ $(/usr/bin/uname -s) == Darwin ]] || die "Requires macOS."
cd "$(dirname "${BASH_SOURCE[0]}")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ProsodyLifecycleBenchmark.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' 'Send the invoice.' > "$scratch/command.txt"
/usr/bin/say -v Samantha -r 185 -f "$scratch/command.txt" -o "$scratch/command.aiff" ||
  die "The local macOS Samantha voice is required to make the fixture."
/usr/bin/afconvert -f WAVE -d LEI16@48000 -c 1 "$scratch/command.aiff" "$scratch/command.wav"

echo "Dictation lifecycle fixture | macOS $(/usr/bin/sw_vers -productVersion) | $(/usr/bin/uname -m)"
(cd "$scratch" && /usr/bin/shasum -a 256 command.wav command.txt)
if (( fixtures_only )); then exit 0; fi

args=(--benchmark-dictation-lifecycle
      --fixture "$scratch/command.wav"
      --reference "$scratch/command.txt")
for retention in "${retentions[@]}"; do args+=(--retention "$retention"); done
(( baseline_loader )) && args+=(--baseline-loader)
(( skip_fake )) && args+=(--skip-fake-checks)
(( show_text )) && args+=(--show-text)

if [[ -n "$binary" ]]; then
  "$binary" "${args[@]}"
  exit $?
fi
swift run --force-resolved-versions --configuration release ProsodyValidation "${args[@]}"
