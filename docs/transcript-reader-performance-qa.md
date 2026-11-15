# Transcript Reader Native Performance QA

This plan validates the native reader on macOS 15 or later. It is a QA fixture
plan; the current change does not run the app UI.

## Fixtures

Create two disposable session folders under the app's normal session root. Each
folder contains `session.json`, `transcript.json`, a Markdown transcript, and
retained audio under `audio/system/`.

1. **10k reader fixture**
   - 10,000 visible segments over 45 minutes.
   - Three audio chunks of about 15 minutes each, named `000001.m4a` through
     `000003.m4a`.
   - Stable UUIDs generated once and reused by the transcript and checks.
   - A 0.25-second gap every 17 rows.
   - A 1.5-second overlap every 53 rows, using the later row as the expected
     playback target.
   - 1% echo-duplicate rows to verify they stay out of the reader projection.
   - Six speaker names, including one renamed speaker.

2. **50k stress fixture**
   - 50,000 visible segments over four hours.
   - Eight 30-minute audio chunks. The same encoded 30-minute source may be
     copied under eight chunk names when only playback mapping is under test.
   - The same gap, overlap, echo, and speaker distribution as the 10k fixture.
   - One 20-minute silent span to check the empty-looking region while scrolling.

Generate the JSON with the existing `SessionStore` models in a disposable Swift
test or validation executable. Do not add a production fixture dependency. The
audio can be produced with the existing `AudioArchiveWriter` or any local AAC
encoder already available on the QA machine.

## Native QA Pass

Run the app from the built `.app` bundle, open each fixture, and record results
in a table with machine, macOS build, fixture, and pass/fail.

1. Confirm the title, date, duration, and retained-audio status are visible
   before the transcript list. Confirm there are no Start, Resume, Pause, or
   Finish recording controls in the reader.
2. Scroll from the first row to the last row with trackpad momentum. Check for
   blank rows, visible recycling artifacts, and text-selection failures.
3. Select text across several rows; copy it. Use Copy Raw and Copy Markdown and
   compare the clipboard with the source transcript.
4. Rename a speaker from one row and from the speaker editor. Confirm the list
   keeps its scroll position and stable row identity.
5. Search for a phrase in the first, middle, and last chunks. Confirm search
   suspends follow, keeps the query intact, disables Follow Audio with the help
   text "Clear transcript search to follow audio," and restores follow after
   clearing the query when follow was enabled before the search.
6. Start playback and let it cross at least two chunk boundaries. Confirm the
   highlighted row advances, the list follows, and the transport time matches
   the source clock.
7. Drag the timeline thumb rapidly across the full duration while auto-follow
   is off. Confirm the highlight still moves with the thumb, the audio seeks
   once when the drag ends, row animations stay disabled during the drag, and
   Follow Audio remains off afterward. Repeat with a nonempty transcript search
   and confirm the filtered list does not scroll.
8. Pause, scrub, resume, and switch sessions while playing. Confirm the old
   session stops, the new session starts at zero, and no old timer updates the
   new transport.
9. Turn on Reduce Motion and repeat the large-jump scrub. Confirm the list jumps
   directly to the target without animation.
10. Open a session with no retained audio and a session whose audio files are
    missing. Confirm the reader still supports search, copy, notes, rename, and
    Reveal, and that the unavailable-audio state is explicit.
11. Start playback, close the retained transcript window, and reopen it. Confirm
    audio stops on close and does not resume until the user presses Play.
12. Inspect the timeline density for a session whose transcript ends well before
    the retained audio. Confirm the speech marks stop at the last speech time
    and trailing silence remains blank.
13. Select a four-hour, eight-chunk fixture and measure the first selection.
    Confirm AV metadata inspection is off the main actor, the preparing state is
    visible, and switching sessions quickly cannot apply stale chunk metadata.
14. Scroll the 50k fixture while playback is active. Confirm no audio file is
    opened or decoded by scrolling and the static density Canvas does not redraw
    on each five-Hz transport tick.

## Measurements

Use Instruments Time Profiler, SwiftUI, Allocations, and Core Animation on the
10k fixture first, then repeat only the failures on the 50k fixture.

- Document open to first readable row: target under 250 ms; no more than one
  timeline projection build for the document.
- Search keystroke to filtered rows: target under 100 ms for 10k rows; one
  projection per changed query.
- Playback idle CPU: no timer activity while paused.
- Playback CPU during the five-Hz transport update: target under 5% on the QA
  machine, with no transcript sort, filter, or full diff in the sample.
- Scrub: highlight changes while dragging; one source seek and at most one
  chunk open per drag unless the final target crosses a chunk boundary.
- Exact timestamps: seeking to every chunk boundary and to long-fixture row
  starts lands on the expected row/chunk with no cumulative drift.
- Chunk-boundary playback: source time remains continuous within 100 ms of the
  expected cumulative offset.
- Fast scroll: no dropped-frame run longer than 100 ms; no row geometry code in
  the Time Profiler sample.
- Memory: target under 250 MB for the 10k fixture and under 400 MB for the 50k
  fixture after scrolling to the end and back.

## Regression Checks

- `TranscriptTimelineTests` covers gap, overlap, equal-start, first/last
  boundary, 12k-row exact lookup, non-finite filtering, speech-end density,
  single cache publication, search projection count, explicit-scrub follow
  policy, and row-change-only follow directives.
- `SessionAudioPlayerTests` covers cumulative chunk offsets, exact boundaries,
  same-chunk seeks without reopening, real WAV playback across a chunk, pause
  stability, resume, session switching, async stale-load rejection, scrub
  preview/commit, and retained-window close stopping playback.
- Run the focused tests on the same macOS 15 machine used for native QA.
