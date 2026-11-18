# Prosody release validation

Use an isolated demo profile for native tests. Test clips should be generated
locally or come from public speech fixtures. Keep recordings, model assets,
and raw machine logs out of the repository.

| Area | Checks | Pass condition |
| --- | --- | --- |
| Shortcut input | Right and left modifiers together, hold and toggle, chord release order, repeats, Escape, interrupted and re-enabled event tap | One start and one finish per accepted press; no commit on cancel or a lost release |
| Dictation lifecycle | Tap below 250 ms, exact threshold, silence, speech ending at release, cancel during capture and fallback, queue overflow, model reuse and eviction, changing native sample rate, session restart | No text or history for no-ops and canceled work; full transcript for successful speech; no stale audio |
| Model and latency | Cold and warm speech, short and long clips, 16 and 48 kHz input, a clip crossing the AAC chunk boundary, forced file fallback | Expected words and final phrase, correct duration, no unexpected fallback; report release-to-text distributions without a machine-specific cutoff |
| Text delivery | Standard paste and Unicode typing, unchanged caret, moved caret and focus, secure fields, rich and multi-item clipboard, a newer copy during restoration | Paste once in the intended field; unsafe destinations offer Copy Text; clipboard changes made afterward survive |
| Native capture and storage | Actual microphone, system audio, pause/resume/finish, keep audio on and off, file import, cancellation and recovery | Expected transcript and playable retained audio; no duplicate sessions or stale capture state |
| Recorder | Open with zero, one, and multiple selected labels; add and clear selections with picker open; switch source; record, pause, resume, and finish | Label picker and controls stay in place when selection changes; primary actions remain reachable; warnings and saved notice still appear |
| Settings and Transcripts | Search by control name and intent; select a result using click and arrow keys/Return; try empty results and Escape; exercise close, minimize and restore, header dragging, native fullscreen on both Settings and Transcripts, and library resize | Search opens and reveals the matching control; both windows enter native fullscreen and return to windowed mode; window controls remain native; content does not overlap them |
| Appearance and dictation HUD | Inspect light and dark fixed themes and Frosted Glass; toggle Reduce Transparency; switch and reopen windows; try Standard and Minimal dictation pop-ups | Content remains readable, the opaque fallback works, and theme choice persists; the dictation pop-up closes at delivery and fallback output stays copyable |
| Distribution | Matching bundle ID and signing requirement; DMG checksum, mount, and notices; upgrade from previous build; normal launch | Mounted app matches the staged app; the archive has notices and no models; preferences and grants carry over |

## Automated gates

- Run [the test script](../script/test.sh) with Xcode selected. It runs Swift
  Testing and XCTest plus the standalone service checks, which cover storage,
  recording lifecycle, recovery, archive formats, transport, and settings.
- With Parakeet Unified installed, run [the model benchmark](../script/benchmark_dictation.sh)
  with **--thorough --compare-archive**. It checks actual transcript quality,
  no-ops, fallback and archive rollover using generated fixtures, then compares
  the live path with the earlier file-first path. For a release comparison, run
  both candidates on the same Mac with the same fixture and cache policy.
  Report sample counts and dispersion; keep idle resource samples separate
  from speech timing.

## Native gates

Use the Prosody debug app with **--demo --show-controls --dictation-fixture** and the
fixture controls in **Settings → Dictation**. Pass a short mono file from a
temporary directory via **--dictation-audio-fixture** to exercise recognition
and insertion without using a microphone. For a microphone test, instead pass
**--dictation-microphone-fixture** with a short, known clip, select the built-in
microphone, and start the fixture. The clip plays once through the built-in
speakers without changing the system output device. The fixture requires
existing microphone permission. A disposable native editor is the target.

For real recording controls with isolated output, use **--demo --show-controls
--hardware-recording-fixture** and existing permissions. Record known audio,
pause and resume, then confirm the saved transcript and decode the archive
when retention is enabled. Try an audio-file import separately.

For a distributed build, use the reviewed candidate for the final launch, upgrade, Gatekeeper, and checksum checks.
Fixture flags and playback helpers are not available in release builds.
