# Dictation performance

Prosody feeds microphone PCM to Parakeet Unified during dictation and finishes the remaining context on release. It adds one frame of software padding at the end so the resampler can flush the final syllable without waiting for more microphone audio. A bounded queue separates capture from inference.

With microphone and Accessibility grants already in place, Prosody starts preparing the installed model at launch. A new shortcut press can start or join that preparation before speech reaches the decoder. Preparation never downloads model files. If the user releases the shortcut while preparation is still pending, the pop-up reports it separately from transcription. Escape ends the current attempt immediately. An ongoing Core ML load can finish without that attempt and is available to a new request while the cache is still valid.

Live recognition and archive replay reuse the same weights after resetting the decoder. Capture continues writing the complete temporary audio when the live queue fills. If recognition fails and usable audio was captured, the recorder offers that audio through Recovery. The model cache expires five minutes after preparation or the last use. Normal recording and import request the dictation cache be released before loading their own model. No microphone or inference work runs between dictations.

While prepared, the dictation model appears in the process footprint as roughly
580 MB of unmapped Neural Engine model state. Releasing it returns that
residency while idle CPU remains at 0%. A warm reload measured around 200–250 ms
in the lifecycle benchmark. A fresh process can require tens of seconds while
Core ML prepares its model and Neural Engine specialization, which is why launch
and gesture preparation use the same shared load rather than a second model.

## Measure on your Mac

Install Parakeet Unified in **Settings → Models**. From the project folder, run the release benchmark with one or more short audio files:

```sh
say -v Samantha -r 185 -o /tmp/prosody-command.aiff 'Send the invoice.'
swift run -c release ProsodyValidation --benchmark-dictation /tmp/prosody-command.aiff /tmp/prosody-command.aiff
```

The tool measures from simulated release until text is ready. **File** closes and reopens the AAC archive, loads the model, and replays the whole clip as alpha.5 did. **Live** feeds the same PCM at capture cadence through the current dictation pipeline. It prints timings and word counts, with exact text comparison in paired runs. Use **--show-text** only for fixtures whose transcription you want printed. **--archive-only**, **--streaming-only**, and **--no-cache** isolate the respective paths and model reuse. The tool uses local files and does not open the microphone, paste, or add history.

To reproduce the release check with generated speech fixtures, run
`./script/benchmark_dictation.sh --thorough --compare-archive`. It also
checks silence, short taps, sample rates, transcript endings, and forced
replay across an archive chunk boundary.

The lifecycle benchmark reports model preparation, release-to-text timing,
process CPU and memory, idle eviction and reload, and cancellation while the
model is loading. Compare retention periods with the same generated clip:

```sh
./script/benchmark_dictation_lifecycle.sh --retention 10 --retention 20 --retention 30 --baseline-loader
```

Use the same Mac and model files for a before/after run. The paired script
takes two already built validation executables and prints the fixture hashes:

```sh
./script/benchmark_dictation_paired.sh --baseline-binary /path/to/baseline/ProsodyValidation \
  --candidate-binary /path/to/candidate/ProsodyValidation --thorough
```

The process resource measurements exclude the system's Core ML helper
processes and do not measure battery drain. A new executable can trigger a
one-time Neural Engine specialization that dominates a cold sample. Keep
that result separate from a fresh process with an existing Core ML cache.
See the [local candidate review](dictation-readiness-review.md) for the paired
results and test coverage.

The optional **--benchmark-nemotron <compiled-tier-directory> <audio-file> …** command compares a locally available Nemotron multilingual Core ML export. It does not install or select the model in Prosody.

To measure a normal dictation from the shortcut to insertion event dispatch:

```sh
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "com.openai.clippy" AND category == "dictation-latency"'
```

The log shows capture stop, queued packet drain, when text was ready, and when the paste or typing events were posted. The destination app controls when it handles those events. Clipboard restoration happens after paste dispatch and is excluded from that timing. The timing log does not include dictated text.

For an app-level test without using a live microphone, stage a debug build and replay a mono audio fixture through the existing UI fixture controls:

```sh
PROSODY_DIST_DIR="$PWD/dist/dictation-test" ./script/build_and_run.sh --stage
open -n "$PWD/dist/dictation-test/Prosody.app" --args \
  --demo --show-controls --dictation-fixture --dictation-audio-fixture /tmp/prosody-command.aiff
```

The compatibility alias for the staging variable is `CLIPPY_DIST_DIR`.

In **Settings → Dictation**, select a disposable editor under **UI test destination** and start the fixture. Demo mode keeps preferences and history isolated. This exercise covers PCM feed, transcription, and insertion; a physical shortcut and microphone test also covers hardware capture.

## Alpha 8 matched comparison

The final Alpha 8 candidate (`be98d5bd88b35348bba10ded33ed4df700b06609`, build 11) was compared with the exact `v1.2.0-alpha.6` baseline (`209784a4b6aefbbd77b2b82a57e6c7aa164d579e`, build 9) on the same Apple M1 Pro, macOS 15.8, installed Parakeet Unified model, release build, cache policy, and generated Samantha fixtures. Both `--thorough --compare-archive` logs recorded matching fixture SHA-256 hashes. Times are release-to-text-ready, before paste; warm means reuse within the cache window.

| Fixture | Alpha 6 warm median (range, n) | Alpha 8 warm median (range, n) | WER |
| --- | ---: | ---: | ---: |
| 0.887 s command, 48 kHz | 61.7 ms (56.5–66.9, n=4) | 56.7 ms (55.7–66.2, n=4) | 0.0% |
| 4.192 s paragraph, 48 kHz | 102.2 ms (89.3–122.7, n=5) | 127.0 ms (104.1–132.5, n=5) | 0.0% |
| 0.887 s command, 16 kHz | 58.8 ms (55.4–61.3, n=5) | 63.1 ms (56.3–73.8, n=5) | 0.0% |
| 65.573 s recording, 48 kHz | 106.8 ms (n=1) | 108.6 ms (n=1) | 0.4% (1/265) |

The original matched run showed a paragraph regression signal: +24.8 ms at the median, with overlapping trial ranges. The earlier audit's roughly +15 ms signal was directionally consistent. Command differences are within overlapping ranges. The cold command was 69.3 ms for Alpha 6 and 104.4 ms for Alpha 8 (one trial each), so it is not a stable comparison.

### Focused paragraph alternating repeat

A focused follow-up alternated the two builds for five rounds per build, with 20 warm samples per build. The medians of the round medians were 112.85 ms for Alpha 6 and 113.15 ms for Alpha 8; the paired median delta was +0.4 ms. The initial paragraph gap did not reproduce. This repeat does not change the original matched table above and is not a speedup or battery claim.

The forced fallback used two AAC chunks and produced the same long-fixture text and WER in both runs: 2,370.8 ms for Alpha 6 and 2,357.8 ms for Alpha 8 (one trial each). The previous file-first path produced medians of 230.3/328.0/227.8/2,444.5 ms for Alpha 6 and 221.9/326.9/225.4/2,440.7 ms for Alpha 8 across the command, paragraph, 16 kHz command, and long fixtures. Paragraph and long text matched the live path; short-command text differed from live in both candidates. These single-run and file-path results do not establish a speedup.

Limits: this is one host and one installed model. The benchmark excludes hardware capture and OS paste. The synthetic PCM hot-path tool reported 36–79% lower CPU time for alternative direct-downmix/reuse implementations; those alternatives are not the changed Alpha 8 candidate algorithm, so the result is tool-only and does not establish product performance or battery life. The Nemotron comparison is unavailable because the experimental compiled tier is missing. These measurements also exclude native window, capture, insertion, and per-process resource checks.

## M1 Pro comparison

The following table is the earlier Alpha 6 historical run, not the Alpha 8 matched comparison above. Measurements are on macOS 15.8 with release builds and locally generated speech.
Times run from simulated shortcut release to text ready, before paste.

| Clip | Alpha.5 file path | Alpha.6 live path, warm |
| --- | ---: | ---: |
| 0.887 s command, 48 kHz | 350.2 ms median (5) | 64.2 ms median (4; 51.9–71.1 ms) |
| 4.192 s paragraph, 48 kHz | 442.2 ms median (5) | 125.3 ms median (5; 103.5–127.4 ms) |
| 0.887 s command, 16 kHz | 345.9 ms median (5) | 57.3 ms median (5; 56.8–68.1 ms) |
| 65.573 s recording, 48 kHz | 3,101.4 ms (1) | 128.1 ms (1) |

The first short 48 kHz trial with no loaded model took 252.8 ms. The command
and paragraph had no word errors. The long fixture had one word error in
265 words and preserved the final sentence, both on the live path and when
forced to replay two AAC chunks. A 240 ms tap and 700 ms of digital silence
produced no text. No speech trial unexpectedly fell back to replay.

In an acoustic test, the built-in microphone picked up the short command,
Prosody dispatched paste 187 ms after capture ended, and the native test
editor received it about 52 ms later. In a separate physical shortcut test,
it took 407 ms to dispatch, including time for the shortcut modifiers to
clear, and another 16 ms for the editor to receive it. These are individual
app measurements, not benchmark medians.

On the first run of a new benchmark binary, Core ML took about 35 seconds to specialize the encoder for the Neural Engine. Relaunching the same binary reused that work.
