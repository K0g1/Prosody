# Dictation readiness review

Local candidate based on Beta 1 (`9a0a85f`). Measurements were taken November 15, 2026 on an Apple M1 Pro with 16 GiB RAM, macOS 15.8, Xcode 16.4, and the installed Parakeet Unified model. The installed bundle and GitHub releases are outside this change.

## Behavior

- Launch, explicit model installation, and a new dictation gesture can start the same installed model preparation. Launch preparation requires existing microphone and Accessibility grants. The app can capture audio while Core ML works, and distinguishes model preparation from recognition.
- Cancel removes the uncommitted request from the UI and queue immediately. It detaches the waiter from model preparation; native work can finish separately. The microphone still shuts down in order before a new capture takes it. Completed text and audio keep their existing delivery and save rules.
- Live recognition and full archive replay share the model and reset its decoder between passes. An unusable manager is replaced only after cleanup. If recognition fails with usable captured audio, Recovery offers that audio. An intentional cancellation still discards the unfinished attempt, and completed sessions still obey **Keep original audio**.
- **Smart sentence capitalization** is on by default for paste and keyboard typing. It uses a bounded prefix of the verified selection, preserves the trailing space and saved transcript, does not read secure fields, and leaves casing unchanged if context or the initial word is ambiguous.

## Paired dictation benchmark

The two release executables ran sequentially on the same generated audio. Both passed the short tap, digital silence, command, paragraph, and forced replay checks. Command and paragraph word error rate was 0%. Live latency is scheduled release to text ready, before paste.

| Measurement | Beta 1 | Candidate |
| --- | ---: | ---: |
| First live 0.887 s command, without prewarm (one fresh-process sample each) | 33,325.8 ms | 30,433.3 ms |
| Warm command median (2 each) | 66.9 ms | 61.8 ms |
| Warm 4.192 s paragraph median (3 each) | 115.0 ms | 110.5 ms |
| Paired run process CPU time (user + system) | 5.18 s | 5.21 s |
| Paired run peak RSS | 603.4 MiB | 627.3 MiB |

The initial samples include substantial Core ML preparation. They are single samples from different executables, so the gap does not establish a faster model load. The change moves preparation ahead of capture when possible. In the forced paragraph replay, Beta 1's file-only path took 357.1 ms, including a 197.5 ms model load. The candidate deliberately completes real live inference before injecting failure, then replays in 145.6 ms with **one live load and zero replay loads**. Its whole failure cycle includes the live pass and is not comparable to the Beta 1 file-only timing.

An earlier control run on the machine under heavier system load produced a 194,929.5 ms Beta 1 cold sample and its long live clip used archive fallback. That run is useful evidence of the slow-load failure mode; it is excluded from the paired numbers above.

The candidate's thorough run passed separately. Its first command after the Core ML cache had been populated was ready in 64.5 ms. Warm medians were 57.8 ms for the 48 kHz command (4 trials), 108.1 ms for the paragraph (5), and 60.5 ms for the 16 kHz command (5). The 65.573 s live clip was ready in 127.9 ms. Forced recovery from its two AAC files took 2,234.2 ms for the archive replay phase, after a deliberately failed live pass, with one live load and zero replay loads. Both long results had 0.4% word error rate (1/265) and preserved the final words; the short speech fixtures had 0%.

## Preparation, cancellation, and idle memory

In the initial lifecycle comparison after Core ML specialization, a fresh recognizer with no prewarm delivered the short command 73.1 ms after release. With simulated launch preparation, scheduling the load took 0.036 ms, preparation took 211.2 ms, and the first command was ready 78.2 ms after release. Starting preparation at the gesture after eviction gave 65.6 ms release to ready. The back-to-back fixture, fed without capture pacing, took 49.5 ms from the end of the feed to text ready. These are different phases in one process, not averages for a macOS app launch.

The previous cancellation behavior was reproduced with a direct load of the same Core ML model and a waiter that joined that native operation: the cancellation waited 180.6 ms. The new cancellable waiter returned in less than 0.1 ms, and a replacement waiter joined the same load and became ready 207.1 ms later. A separate controller test holds the native load indefinitely and checks that cancellation changes the UI state synchronously, the replacement begins capture, and no cancelled output is saved or delivered.

| Trial cache window | RSS just before / just after eviction | Reload | Mean idle CPU |
| --- | ---: | ---: | ---: |
| 10 s | 40.6 / 39.4 MiB | 198.2 ms | 0.0% |
| 20 s | 37.5 / 37.3 MiB | 232.1 ms | 0.0% |
| 30 s | 35.2 / 34.8 MiB | 248.5 ms | 0.0% |

These retention trials compare three sequential intervals in one process, so the absolute RSS readings are not comparable between intervals. In a same-process AppKit comparison, the loaded model added roughly 25 MiB RSS and 4 MiB private physical footprint, plus about 584 MiB of clean, reclaimable Neural Engine mapping. CPU and energy-impact samples round to 0.0% both while resident and after eviction. The product therefore retains the model for five minutes to avoid reload work across ordinary pauses while preserving explicit release before recording/import and bounding idle residency. There is no inference, microphone work, or polling during that window. The resource figures describe the test process; system Core ML services, the window server, and a full battery-drain measurement remain outside this comparison.

## Verification

`script/test.sh` passed: 149 XCTest cases, 23 Swift Testing cases, and the standalone `ProsodyValidation` checks. Focused coverage includes 14 model lifecycle, 25 controller and queue, and 26 capitalization tests. The tests cover hold and toggle, immediate next capture, phase order, cancellation with a suspended load, stale event handling, cache expiry, fallback when capture overflows, recovery, and existing clipboard and settings behavior. A two-part archive adoption test reopens Recovery and compares the recovered bytes after temporary cleanup.

Native probes ran the actual insertion code against disposable AppKit controls, TextEdit, Safari, and an isolated VS Code editor. They checked empty fields, sentence boundaries, mid-sentence insertion, selection replacement, abbreviations, quotes, Unicode, clipboard restoration, and change-of-focus rejection. The Safari custom control received the original lowercase text without caret context. Password controls were not read or written. The accessibility range request is optional; see [Apple's range attribute documentation](https://developer.apple.com/documentation/applicationservices/kaxstringforrangeparameterizedattribute).

The staged app relaunched in a separate process and recognized fixture audio. Its automated destination selection did not establish an end-to-end delivery pass, so the staged UI result does not prove consecutive dictation or cancellation. Those paths passed the controller tests. Notes did not provide a safe local note editor for the probe; its search field did not yield a verified insert. A physical microphone session was not tested. One early native test driver crashed before restoring the pre-test clipboard; subsequent runs used a separate clipboard guard and restored it.
