#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/benchmark_dictation.sh [--quick | --thorough] [--repeat N]
                                    [--compare-archive] [--fixtures-only]
                                    [--binary PATH]

Runs an optimized ProsodyValidation against the locally installed Parakeet
Unified model. No mic, UI, clipboard, history, or model downloads.

  --quick            Tap, silence, two speech clips, and forced AAC recovery.
                     Default: 3 trials per speech clip, about 16s of replay.
  --thorough         Also test 16 kHz and a speech clip that crosses the 60s
                     AAC boundary. Default: 5 trials per short speech clip,
                     one long trial and one recovery from the multi-part AAC.
  --repeat N         Override the repeat count for the short speech clips.
  --compare-archive  Also time the previous file-first path (diagnostic).
  --fixtures-only    Generate and verify the audio, without Swift or Core ML.
  --binary PATH      Run an already-built ProsodyValidation binary instead of
                     `swift run` (relative paths are resolved before chdir).

The first speech trial is reported separately from warm trials. Correctness
gates check no-ops, transcript words and endings, duration, and AAC recovery;
timings have no machine-specific pass/fail limit. Run without other model
benchmarks or recordings for comparable timings. Use DEVELOPER_DIR to select
a Swift toolchain if needed.
EOF
}

die() { echo "benchmark_dictation.sh: $*" >&2; exit 1; }
mode=quick
repeats=
compare_archive=0
fixtures_only=0
binary=
while (( $# > 0 )); do
  case "$1" in
    --quick) mode=quick ;;
    --thorough) mode=thorough ;;
    --repeat)
      shift
      [[ ${1:-} =~ ^([1-9][0-9]?|100)$ ]] || die "--repeat must be an integer from 1 to 100."
      repeats=$1
      ;;
    --compare-archive) compare_archive=1 ;;
    --fixtures-only) fixtures_only=1 ;;
    --binary)
      shift
      [[ -n ${1:-} ]] || die "--binary requires a path."
      if [[ "$1" = /* ]]; then
        binary=$1
      else
        binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
      fi
      [[ -x "$binary" ]] || die "--binary is not executable: $binary"
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[[ $(/usr/bin/uname -s) == Darwin ]] || die "Requires macOS."
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ -z "$repeats" ]]; then
  if [[ "$mode" == thorough ]]; then repeats=5; else repeats=3; fi
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ProsodyDictationBenchmark.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Stock local voice, fixed scripts and cadence. All audio is generated in the
# scratch directory and discarded automatically. Never use user recordings.
synthesize() {
  local name="$1"
  /usr/bin/say -v Samantha -r 185 -f "$scratch/$name.txt" -o "$scratch/$name.aiff" ||
    die "The local macOS Samantha voice is required to make the fixtures."
  /usr/bin/afconvert -f WAVE -d LEI16@48000 -c 1 "$scratch/$name.aiff" "$scratch/$name-source.wav"
}

printf '%s\n' 'Send the invoice.' > "$scratch/command.txt"
printf '%s\n' 'Please move the morning meeting to Friday. Bring the blue folder and leave a note on my desk.' > "$scratch/paragraph.txt"
synthesize command
synthesize paragraph
if [[ "$mode" == thorough ]]; then
  cat > "$scratch/long-body.txt" <<'EOF'
The library opens early on Saturday. A clerk unlocks the front door and sets a tray of maps beside the entrance. A family stops to look at the new books while a student finds a quiet table by the stairs.
Across the street, the bakery puts fresh bread in the window. The baker carries two paper bags out to a neighbor waiting on the corner. They talk about the rain and watch a bus pull away from the stop.
Later in the morning, the park fills with people. Some walk along the path beside the pond. Others sit on the grass and unpack their lunch. A child points to a duck that is swimming toward the bridge.
By the time the sun comes out, the clouds have moved over the hills. The student closes a book and walks back to the library desk. The clerk puts the maps in a drawer and turns off the lamp. A delivery driver rings the bell and waits beside the door.
EOF
  printf '%s\n' 'Please leave the green notebook by the window.' > "$scratch/long-ending.txt"
  synthesize long-body
  synthesize long-ending
fi

/usr/bin/python3 - "$scratch" "$mode" <<'PY'
from array import array
from pathlib import Path
import sys
import wave

root = Path(sys.argv[1])
rate = 48_000
frame_bytes = 2


def pcm(name):
    with wave.open(str(root / (name + "-source.wav")), "rb") as src:
        if (src.getframerate(), src.getnchannels(), src.getsampwidth()) != (rate, 1, frame_bytes):
            raise SystemExit("Unexpected format for " + name)
        data = src.readframes(src.getnframes())
        if len(data) < rate * frame_bytes // 2 or not any(abs(sample) >= 512 for sample in samples(data)):
            raise SystemExit("No usable synthesized speech in " + name)
        return data


def samples(data):
    result = array("h", data)
    if sys.byteorder == "big":
        result.byteswap()
    return result


def write(name, data):
    with wave.open(str(root / (name + ".wav")), "wb") as dst:
        dst.setparams((1, frame_bytes, rate, 0, "NONE", "not compressed"))
        dst.writeframes(data)
    print(f"  {name}.wav: {len(data) / (rate * frame_bytes):.3f}s, mono {rate} Hz")


def zeros(seconds):
    return bytes(round(rate * seconds) * frame_bytes)


command = pcm("command")
values = samples(command)
peak = max(range(len(values)), key=lambda i: abs(values[i]))
last_voiced = next(i for i in range(len(values) - 1, -1, -1) if abs(values[i]) >= 64)
write("command", command[:(last_voiced + 1 + round(0.04 * rate)) * frame_bytes])

# Cut actual voiced audio just below the 250 ms no-op threshold, and cover a
# separate all-zero clip well above the threshold.
tap_frames = round(0.24 * rate)
start = max(0, min(peak - tap_frames // 2, len(values) - tap_frames))
write("tap", command[start * frame_bytes:(start + tap_frames) * frame_bytes])
write("silence", zeros(0.7))
paragraph = pcm("paragraph")
write("paragraph", paragraph)

if sys.argv[2] == "thorough":
    body = pcm("long-body")
    reference = (root / "long-body.txt").read_text(encoding="utf-8")
    # Voice versions can speak at slightly different rates. Ensure the
    # distinctive final sentence is spoken entirely after the AAC rollover.
    while len(body) < round(60.10 * rate) * frame_bytes:
        body += zeros(0.2) + paragraph
        reference += (root / "paragraph.txt").read_text(encoding="utf-8")
    ending = pcm("long-ending")
    audio = body + zeros(0.2) + ending
    if len(audio) > 90 * rate * frame_bytes:
        raise SystemExit("Long fixture exceeds 90 seconds; check the macOS voice rate.")
    write("long", audio)
    (root / "long.txt").write_text(reference + (root / "long-ending.txt").read_text(encoding="utf-8"), encoding="utf-8")
PY

files=(tap.wav silence.wav command.wav paragraph.wav)
if [[ "$mode" == thorough ]]; then
  /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$scratch/command.wav" "$scratch/command-16k.wav"
  files+=(command-16k.wav long.wav)
fi

echo "Dictation audit: $mode | macOS $(/usr/bin/sw_vers -productVersion) | $(/usr/bin/uname -m) | Samantha at 185 wpm"
echo "Fixture SHA-256 (macOS voice assets can vary by host):"
(cd "$scratch" && /usr/bin/shasum -a 256 "${files[@]}")
if (( fixtures_only )); then exit 0; fi

args=(--benchmark-dictation)
if (( ! compare_archive )); then args+=(--streaming-only); fi
args+=(--expect-no-op "$scratch/tap.wav" --expect-no-op "$scratch/silence.wav")
args+=(--repeat "$repeats" --reference "$scratch/command.txt" "$scratch/command.wav")
if [[ "$mode" == quick ]]; then
  args+=(--verify-fallback --reference "$scratch/paragraph.txt" "$scratch/paragraph.wav")
else
  args+=(--reference "$scratch/paragraph.txt" "$scratch/paragraph.wav")
  args+=(--reference "$scratch/command.txt" "$scratch/command-16k.wav")
  args+=(--repeat 1 --verify-fallback --reference "$scratch/long.txt" "$scratch/long.wav")
fi
if [[ -n "$binary" ]]; then
  "$binary" "${args[@]}"
else
  swift run --force-resolved-versions --configuration release ProsodyValidation "${args[@]}"
fi
