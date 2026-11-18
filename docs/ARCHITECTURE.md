# Architecture

Prosody is a Swift Package Manager project with an AppKit shell and a SwiftUI interface. The coordinated beta rename uses `ProsodyCore`, `ProsodyApp`, and `ProsodyValidation`; their source paths are `Sources/ProsodyCore`, `Sources/ProsodyApp`, and `Tools/ProsodyValidation`. The packaged app and archive use the Prosody name, while compatibility identifiers from Clippy remain in the bundle and storage contracts.

## Runtime shape

```text
ProsodyApp
  ├─ AppKit application shell / status item / foreground windows
  └─ AppDelegate
       └─ AppWindowController
            └─ AppModel.shared (main-actor source of UI truth)
            ├─ ScreenCaptureCoordinator  ── ScreenCaptureKit
            ├─ STTRegistry ─────────────── ParakeetEngine / mock engine
            ├─ TranscriptCoordinator ────── streaming transcript assembly
            ├─ AudioArchiveWriter ───────── recoverable audio chunks
            ├─ RecoveryStore ────────────── checkpointed state and segments
            ├─ AudioFileTranscriber ─────── bounded file/deferred transcription
            ├─ DictationController ──────── shortcut, HUD, queue, insertion
            ├─ SessionStore ─────────────── completed sessions and index
            └─ NotesProvider ────────────── local outline / compatible notes
```

## Application and state

`Sources/ProsodyApp/main.swift` starts the AppKit application shell. `AppWindowController` owns the status item, recorder popover, right-click menu, reusable Settings and Transcripts windows, foreground activation, and the nonactivating dictation HUD. A normal launch uses accessory activation and shows no main window. Reopening the running app or choosing **New Recording** from the library shows the menu-bar recorder. The separate recorder window is a QA surface selected with `--show-controls`.

`AppModel` is the main-actor source of truth for the recorder, Settings, Transcripts, and dictation overlay. Its lifecycle includes preparing, recording, paused, stopping, finalizing transcript, diarizing, generating notes, completed, and failed states. Views render published snapshots; they do not own recording truth. Pause, resume, finish, recovery, and model changes are serialized so they cannot race the capture pipeline.

Completion retains the completed session identifier while the recorder renders idle controls. A separate identity-guarded saved notice links to the transcript for about five seconds. Starting another recording clears the notice, and a stale completion task cannot dismiss a newer message.

## Recorder, labels, and appearance

The menu-bar recorder is the normal recording surface. Settings and Transcripts open in separate windows with native window controls. The recorder keeps recording actions, status, saved notices, recovery notices, and navigation visible. `MainScreenSection` describes the optional tray content: branding, recording title, labels, audio source, note template, save location, and up to three recent recordings. Preferences store hidden section identifiers, so hiding a control leaves its saved choice intact. **Show All Controls** clears that set.

`RecordingLabelsStudioView` edits labels inside Settings. `RecordingLabelDraftStore` keeps unsaved drafts and folder bookmarks across page recreation and section changes. A label has a stable identifier, name, color, output folder, naming pattern, and date format. The first selected label is primary and supplies the recording title pattern and destination. Labels are snapshotted into saved sessions, so renaming or deleting a label does not rewrite existing files or remove its identity from saved recordings.

`ProsodyTheme` preserves persisted theme identifiers across 95 palettes. Material selection and light/dark appearance are independent. Glass themes use the native NSPopover backdrop in the tray and one AppKit behind-window effect per owned window. Tinted themes add a translucent palette wash. Clear Glass uses grayscale tokens. Reduce Transparency selects an opaque fallback.

## Transcript library and reader

`TranscriptLibraryQuery` filters saved sessions by title and label, an optional label identifier, and an audio-presence filter. It sorts by newest, oldest, recording name, longest, shortest, or label, with a stable UUID tie-break. The library hides dictation by default; **Include Dictation** opts those sessions back in. The **With retained audio** and **Without retained audio** checkboxes both start on, and the UI prevents both from being turned off.

The reader is a separate projection from the library list. `TranscriptReaderCache` builds a chronological `TranscriptTimeline` and filters it by transcript text or visible speaker name. Search suspends automatic following and disables **Follow Audio** until the query is cleared. Manual scrolling also suspends following. Adjacent playback rows center with a cancellable scroll animation that respects Reduce Motion. An explicit timeline scrub can move the highlighted row even when automatic following is off, unless a search is active.

### Optional source kind and legacy inference

`RecordingSession.sourceKind` and `SessionManifest.sourceKind` are optional so manifests and indexes written before the field existed still decode. New sessions write `recording`, `dictation`, or `file`. `SessionSummary.sourceKind` is optional for the same reason, and `hasRetainedAudio` remains optional until the library has inspected the session's files.

`SessionStore` resolves an explicit nonempty kind first. For older data it infers `dictation` only when all of these are true: microphone capture, speakers off, completed status, no transcript filename, no `notes.md`, and a generated `Dictation <date>` title matching the manifest time or the preceding minute. Every other old session is marked `legacy`. The library hides only explicit `dictation` entries, so an old session with an uncertain kind remains visible instead of being silently lost or misclassified.

### Retained audio and playback limits

`SessionAssetResolver` treats a session as having retained audio only when it finds a nonempty regular file in `audio/system`, `audio/microphone`, or the older root-level `system.caf` or `microphone.caf` paths. The index backfills missing source-kind and retained-audio metadata without replacing entries another store instance has written. Moving a session or copying an imported file refreshes that summary.

`SessionAudioTimeline` maps the retained chunks into one cumulative source clock. `SessionAudioPlayer` inspects headers off the main actor, opens one chunk at a time, and keeps decoder memory bounded by the active file. It advances the transport at five updates per second, crosses chunk boundaries without cumulative drift, and stops playback when the transcript window closes. The transport provides five-second back and forward steps. A session without audio, or one whose files are missing, remains readable, searchable, copyable, and usable for notes and Reveal; the unavailable-audio state is explicit.

`TranscriptTimeline` removes echo duplicates and non-finite rows, orders by start, end, and UUID, and looks up the row for a playback time with a binary search. A gap maps to the preceding row; times before the first row map to the first row; times after the last row map to the last row. Overlaps map to the most recently started row. The timeline density uses 240 bins and stops at the last visible speech time, leaving trailing silence blank.

## Dictation queue and delivery

`DictationController` separates capture from finalization. A new shortcut press can start the next utterance while the previous result is being recognized or delivered. The queue holds at most three sessions; finalization remains serial and in release order. Capture and recognition each use a FIFO gate, and cancellation drains queued work without delivering it. A full queue reports that earlier text must finish before another capture can start.

The controller captures the destination application and available Accessibility focus metadata before showing the HUD. Escape before the commit boundary cancels the session and produces no clipboard, insertion, or history output. At the commit boundary the HUD closes while delivery, clipboard restoration, and history saving finish. A tap shorter than about 0.25 seconds, or a longer recording with no visible text, is a no-op.

`DictationTextDestination` rechecks the foreground app, window, focused text control, selection, and secure-field metadata before delivery. Standard paste waits for shortcut modifiers to be released, sends Command-V through the normal HID path, and restores the previous clipboard only if it is still unchanged. Keyboard typing is an explicit compatibility mode. A dispatched paste is never retried automatically; an unsafe destination exposes copyable text instead. Delivered and copied text gets one trailing space while the stored transcript remains clean.

## Capture and transcription

`ScreenCaptureCoordinator` wraps ScreenCaptureKit for system audio and AVFoundation for the microphone. `AudioSampleConverter` normalizes formats, and the meter calculator feeds the UI. `AudioArchiveWriter` writes temporary chunks during recording so a crash can leave recoverable audio. The selected capture mode determines which sources are requested; permissions are requested explicitly before capture.

`SpeechModel` lists the supported models. `STTModelManager` validates model files in a private staging directory and moves a completed package to the cache. Only explicit downloads access the network. The additional TDT models use pinned Core ML manifests with byte counts and SHA-256 hashes for weight files. Unified keeps its previous cache path. Batch models use bounded PCM and FluidAudio’s disk-backed window processing. `ParakeetEngine` is the production adapter around FluidAudio, and `ParakeetStreamingSession` accepts source audio and yields partial and final updates. `TranscriptCoordinator` maintains the canonical transcript; `StreamingTranscriptAssembler`, `TranscriptChunker`, and `EchoDeduplicator` handle partial updates, block boundaries, and duplicate content. `AudioFileTranscriber` decodes bounded PCM chunks for imports and deferred recordings. The optional filler filter removes hesitation sounds and transfers sentence capitalization to the next surviving word. It keeps word times for unchanged words and runs before literal whole-word substitutions. Substitutions run after speaker alignment so reconstructing timed segments preserves corrected text.

## File workflows and automation

The importer accepts a native multi-file selection and an optional saved label, and reuses one prepared model across files. Each file commits an independent session. `TranscriptExportFormatter` renders the user-configurable exports and label copies, while the session store retains its original Markdown and JSON contract. Bulk export preserves library selection order and creates collision-safe filenames. The audio exporter copies the retained tracks separately. The compressor stages verified smaller AAC alternatives and commits them with one directory replacement.

App Intents run in the app’s process. The packaged CLI uses a private per-user UNIX socket and a versioned request protocol. It starts only when enabled and the app is open. Both file automation entry points lease the same recognizer used by dictation and serialize with capture and model selection. Long CLI batches keep a lease scope across files so model retention cannot expire between them. The CLI process has no dependency on Core ML or FluidAudio.


Transcript layout preferences snapshot at the start of each recording, import, recovery, or dictation. The defaults are 40 words per block and a 1.5-second pause; accepted ranges are 10–100 words and 0.5–5 seconds. The reader and stored segments do not rewrite existing transcripts when the preference changes.

## Persistence, recovery, and legacy data

`SessionStore` writes the canonical `transcript.json` first, the Markdown render next, optional `notes.md`, and the `session.json` manifest last as the commit marker. Each completed session has its own directory and is indexed by `SessionIndexStore`. `RecoveryStore` keeps an atomic manifest, append-only finalized segments, and one replaceable provisional tail per audio source; a torn JSONL record is ignored during load.

The beta keeps the bundle identifier `com.openai.clippy` and the previous support location for upgrade compatibility. `ProsodyStorage.applicationSupportDirectory` prefers an existing sandbox support directory at `~/Library/Containers/com.openai.clippy/Data/Library/Application Support/Clippy` and otherwise uses `~/Library/Application Support/Clippy`. Models live under its `Models` directory and recovery data under `Recovery`. Clean installs use `~/Prosody` for output; upgrades keep the saved folder or an existing `~/Clippy`.

`ProsodyPreferences` loads from the dedicated `com.openai.clippy.preferences.v1` suite and persists each setting independently. Keep the suite name across releases. The typed setting codecs accept values from an explicitly chosen prior domain, sandbox plist, or backup. Older app domains remain available for manual import. The new version uses the same current suite after an in-app update. macOS grants and machine-local registrations have their own lifecycles.

## Notes and network policy

The template notes provider creates a deterministic Offline Outline locally. `OpenAICompatibleProvider` supports explicitly configured local or remote OpenAI-compatible endpoints. `SafeURLValidator` enforces local-only mode, permits plain HTTP only for loopback addresses, and rejects redirects before a request is made. API credentials are stored in the Keychain rather than in source or session files. Dictation never generates notes.

## Packaging and release boundary

`Resources/Info.plist` defines the release label, numeric build, permission descriptions, and pinned Sparkle feed and key. The build script embeds the SwiftPM executable, CLI helper, App Intents metadata, Sparkle framework, resources, and notices before signing. Sparkle verifies the feed and archive before extraction. The update delegate waits for active audio work to finish and flushes settings before relaunch.

The release packager verifies the staged app, mounted image, absence of bundled model weights, and SHA-256 checksum. A valid signature proves bundle integrity; it does not establish notarization or Gatekeeper acceptance. See [Releasing Prosody](RELEASING.md).
