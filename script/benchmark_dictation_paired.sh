#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/benchmark_dictation_paired.sh --baseline-binary PATH
       --candidate-binary PATH [--quick | --thorough] [--repeat N]
       [--report-dir PATH]

Runs the existing benchmark_dictation.sh sequentially against two already
built ProsodyValidation binaries through the script's quoted --binary option,
so neither run can rebuild or mutate the checkout.

The script records memory_pressure, /usr/bin/time -l, fixture hashes, and both
exit statuses. It continues to the candidate if the baseline fails. Reports
default to .benchmark-results inside the checkout; pass --report-dir for a
temporary or review directory.
EOF
}

die() { echo "benchmark_dictation_paired.sh: $*" >&2; exit 1; }
baseline=
candidate=
mode=quick
repeat_args=()
report_dir=
while (( $# > 0 )); do
  case "$1" in
    --baseline-binary)
      shift; [[ -n ${1:-} ]] || die "--baseline-binary requires a path"; baseline=$1 ;;
    --candidate-binary)
      shift; [[ -n ${1:-} ]] || die "--candidate-binary requires a path"; candidate=$1 ;;
    --quick) mode=quick ;;
    --thorough) mode=thorough ;;
    --repeat)
      shift; [[ ${1:-} =~ ^([1-9][0-9]?|100)$ ]] || die "--repeat must be 1...100"; repeat_args=(--repeat "$1") ;;
    --report-dir)
      shift; [[ -n ${1:-} ]] || die "--report-dir requires a path"; report_dir=$1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -n "$baseline" && -n "$candidate" ]] || die "Both --baseline-binary and --candidate-binary are required."

resolve_path() {
  local path=$1
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd)" "$(basename "$path")"
  fi
}
baseline="$(resolve_path "$baseline")"
candidate="$(resolve_path "$candidate")"
[[ -x "$baseline" ]] || die "Baseline binary is not executable: $baseline"
[[ -x "$candidate" ]] || die "Candidate binary is not executable: $candidate"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "$report_dir" ]]; then
  report_dir="$(resolve_path "$report_dir")"
else
  report_dir="$repo/.benchmark-results"
fi
review="$report_dir"
mkdir -p "$review"
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$review" == "$repo"/* ]]; then
  report_label="checkout/${review#"$repo"/}"
else
  report_label=external
fi

{
  echo "paired_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "repo=Prosody checkout"
  echo "branch=$(git -C "$repo" branch --show-current)"
  echo "head=$(git -C "$repo" rev-parse HEAD)"
  echo "mode=$mode"
  echo "report_dir=$report_label"
  echo "baseline_binary=$(basename "$baseline") sha256=$(shasum -a 256 "$baseline" | awk '{print $1}')"
  echo "candidate_binary=$(basename "$candidate") sha256=$(shasum -a 256 "$candidate" | awk '{print $1}')"
  /usr/bin/memory_pressure -Q 2>&1
  echo "loadavg=$(sysctl -n vm.loadavg)"
  echo "disk=$(df -h "$review" | tail -1)"
  echo "thermal=$(pmset -g therm 2>&1 | tr '\n' ' ')"
} | tee "$review/paired-environment.log"

run_one() {
  local label=$1 binary=$2
  local log="$review/paired-${label}-${mode}.stdout.log"
  local repeat_text="${repeat_args[*]:-}"
  local -a benchmark_args=(--binary "$binary" "--$mode")
  if (( ${#repeat_args[@]} > 0 )); then
    benchmark_args+=("${repeat_args[@]}")
  fi
  echo "$label: script/benchmark_dictation.sh --binary <$(basename "$binary")> --$mode $repeat_text" | tee -a "$review/commands.log"
  set +e
  /usr/bin/time -l env NSUnbufferedIO=YES \
    /bin/bash "$repo/script/benchmark_dictation.sh" "${benchmark_args[@]}" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  printf '%s_exit=%s\n' "$label" "$status" | tee -a "$log"
  return "$status"
}

baseline_status=0
candidate_status=0
run_one baseline "$baseline" || baseline_status=$?
run_one candidate "$candidate" || candidate_status=$?

{
  echo "baseline_exit=$baseline_status"
  echo "candidate_exit=$candidate_status"
  /usr/bin/memory_pressure -Q 2>&1
  echo "loadavg=$(sysctl -n vm.loadavg)"
  echo "disk=$(df -h "$review" | tail -1)"
} | tee "$review/paired-summary.log"

(( baseline_status == 0 && candidate_status == 0 ))
