# Using Prosody

Prosody opens in the macOS menu bar. Click its icon for the recorder, or Control-click it for quick actions. **Settings** and **Transcripts** open in separate windows. Use **View → Enter Full Screen** or **Control-Command-F** in either window.

This Markdown guide is the current reference for setup, recording, dictation, transcripts, and privacy. See [Install](#install) for the Beta 3 disk image and first-launch notes.

## Install

Download `Prosody-1.2.0-beta.3.dmg` and its SHA-256 file from [GitHub Releases](https://github.com/K0g1/Prosody/releases). In Terminal, run:

```sh
shasum -a 256 -c Prosody-1.2.0-beta.3.dmg.sha256
```

Open the disk image and drag **Prosody** to **Applications**. This public beta is ad-hoc signed and not notarized. If macOS blocks the first launch, open the Finder context menu for Prosody and choose **Open**, or allow it in **System Settings → Privacy & Security**. Later launches use the normal menu-bar entry.

For an earlier Prosody or Clippy installation, open **Settings → General → Import Preferences…** and select the previous installation or a saved preferences plist. Review the confirmation before applying it. For subsequent releases, **Prosody → Check for Updates…** or the same button in General downloads and installs a signed update after you approve it. Prosody relaunches with the preferences from the version it replaced.

## Set up and record

1. Open **Settings → Models** and download a model. **Parakeet Unified** supports English and live recording. **Parakeet TDT v3** and **Fluid Speech Pro** recognize 25 languages and transcribe recordings after you click Finish. All three support dictation and file transcription. **Open Models Folder** reveals the cache and each installed model has a Delete button.
2. Open **Settings → Audio**. Choose **System Audio**, **Microphone**, or **System + Mic** (the default), then click **Request Permissions**. See [macOS permissions](PERMISSIONS.md) if a grant does not take effect.
3. In the menu bar recorder, choose **Audio** and optionally enter a title, select labels, and check **Save to**.
4. Click **Start Recording**. Use **Pause** and **Resume** to skip a portion. Click **Finish**, then **View** in the saved notice or open **Transcripts** from the recorder footer.

**Settings → Audio → Keep original audio** is off by default. Turn it on for playback of subsequent sessions. **Settings → Transcription → Live transcription** is on by default; turn it off to transcribe after finishing. Under **Transcript layout**, **Maximum words per block** defaults to 40 (range 10–100), and **Pause before new block** defaults to 1.5 seconds (range 0.5–5). Changes apply to the next recording, import, recovery, or dictation.

The global recording shortcut is **Option-Command-R** by default. It starts, pauses, or resumes capture. Change it under **Settings → General → Global recording shortcut**. To finish, use the recorder.

## Dictate into another app

Install and select a model in **Settings → Models**. Open **Settings → Dictation → Enable…**, allow Accessibility access for Prosody, then return and check for **Shortcut ready**. Choose **Allow Microphone…** or grant access on first use.

Click a text field. Hold **Right Command**, speak, and release it. Press the shortcut again for the next utterance while the previous result is still being prepared or delivered. A small queue preserves release order; if it fills, let an earlier result finish before trying again. Keep the intended field focused.

- **Preparing speech model…** means the local model is still loading. Press **Escape** to dismiss an unfinished dictation immediately. A quick tap or silence creates no output.
- In **Settings → Dictation**, change **Shortcut**, switch **Activation** from **Hold to talk** to **Press to start / stop**, or choose the **Minimal** pop-up for a smaller waveform and status.
- **Standard paste** is the default. Try **Keyboard typing** if the editor rejects paste. If Prosody cannot safely insert into the original destination, use **Copy Text** when offered. To keep the result on the clipboard, turn on **Copy output to clipboard**.
- **Smart sentence capitalization** is on by default for both insertion methods. It uses the text before the caret when the editor makes that context available. Prosody leaves the recognized casing alone when context is unavailable and does not read secure fields. Saved transcripts keep their original casing.
- Turn on **Settings → Transcription → Omit filler words** to remove written hesitations such as *um*, *uh*, and *hmm*. This also applies to saved recordings and imports.
- Completed dictations are saved. Open **Transcripts** and turn on **Include Dictation** to see them; the checkbox starts off.

## Read, play, and export transcripts

Open **Transcripts** from the menu bar recorder. The sidebar searches titles and labels. Use the **Label** filter and sort by newest, oldest, recording name, longest, shortest, or label. **With retained audio** and **Without retained audio** are both checked by default; one can be cleared, but the app will not let you clear both. Use the search field in the reader to find spoken text or speaker names within the selected transcript.

For a session with retained audio, click **Play**, click a timestamp to jump to that passage, or drag the timeline to scrub. The skip controls move five seconds at a time. **Following** highlights the passage across the reader and begins centering it just before its start. Reduce Motion switches to direct positioning. Manual scrolling or searching suspends follow. Click **Follow Audio** to resume. Clear the search first if it is active. Reading, search, and copy work without retained audio.

The timeline shows where speech occurs, skips duplicate echo text, and leaves trailing silence blank after the last visible speech time. Long sessions load audio as needed for playback. Closing the transcript window stops playback.

**Copy Raw** copies speech with a blank line between blocks and omits timestamps and speaker names. **Copy Markdown** uses **Settings → Transcript Export** to choose details such as the title, date, timestamps, and speaker names. Open **More Transcript Actions** (the ellipsis) for **Rename Speakers**, **Regenerate Notes**, **Open Notes**, or **Reveal in Finder**.

Choose **File → Transcribe Audio Files…** to select one or more files. Choose a label and decide whether to use the source basenames for the Markdown files. Turn on **Keep original audio** before importing to retain playable copies.

Shift-click a range or Command-click individual rows in the library. Use **File → Export Transcripts** for separate Markdown files, a combined Markdown document, or copies of retained audio. **Edit → Copy Transcript Text** and **Copy Transcript Markdown** work on the selection.

The reader shows the retained audio's file size. **Compress Audio…** replaces the original audio with smaller AAC files after confirmation. Compression is lossy and irreversible. Prosody keeps the original when compression saves no space.

## Labels and folders

Open **Settings → Labels → Add Label**, or select an existing label. Set the name and color, then use **Naming → File naming pattern** and **Date format**. Use **Preview** to check the resulting title and Markdown filename. In **Saving destination**, use **Choose Folder…** or **Use Default Folder**. Select **Create Label** or **Save Changes** to apply the draft. Drafts stay in Settings as you switch labels or sections. Select **Discard Changes** to restore an existing label or **Cancel** to drop a new draft.

Before recording, open **Labels** in the recorder and select one or more. The first selected label is primary. Use **Make Primary** to change it. The primary label sets the title and filename pattern and can override the default output folder. To update a saved transcript's labels, open it and choose **Labels → Save Labels** after editing the selection. This updates its labels without moving or renaming the files.

In a label’s **Transcript Copies** section, choose a separate folder and select **Formatted Markdown**, **Text-only Markdown**, or **Raw Text**. Prosody writes a transcript-only copy for new recordings and imports carrying that label.

## Shortcuts and command line

Select **Prosody** in the Shortcuts action picker. Actions can start, pause, resume, or finish a recording, read its status, transcribe an audio file, find saved transcripts, return text or retained audio, remove filler words, change that preference, and open Prosody windows.

Enable **Settings → General → Enable command-line tool** to install `~/.local/bin/prosody`. The running app handles jobs using the selected model. The CLI can export existing audio files with labels, per-run format overrides, and persistent word replacements. See the [CLI skill](skills/prosody-cli/SKILL.md).

## Appearance, tray, notes, and privacy

- **Settings → Appearance** offers 95 themes in seven groups. **Graphite** is the default. The **System & Glass** group includes blue, amber, iris, rose, sea, and smoked glass. **Clear Glass** uses grayscale controls over the native untinted material. Adaptive palettes follow the macOS appearance and all glass themes respect **Reduce Transparency**.
- **Settings → Tray Elements** controls which optional items appear in the compact recorder. Hiding an item keeps its saved choice. **Show All Controls** restores all optional items.
- **Settings → General → Launch Prosody at Login** is off by default. Use **Open Login Items…** if macOS needs you to approve it.
- **Settings → Replacements → Add Replacement** applies literal, case-insensitive whole words or phrases to future transcriptions. Leave **Replace with** blank to remove a match.
- **Settings → Speakers → Speaker differentiation** defaults to **Basic**, which separates microphone and system audio. **Full** attempts a separate speaker pass after transcription and may download another model.

**Settings → Notes** defaults to automatic notes with **Offline Outline**, which formats the transcript locally. Dictation does not generate notes automatically. To use a server for notes, choose a provider and its model, then check **Test Connection**. **Settings → General → Local-only mode** is on by default. If you turn it off and choose a remote provider, notes requests send transcript text and context such as speaker names and timestamps. Audio capture and speech recognition still run on your Mac. Provider credentials stay in the macOS Keychain. See the [third-party notices](../Resources/ThirdPartyNotices/README.md).

## Recovery, upgrade, and backup

After an interruption, open the recorder. If you see **Unfinished recording**, choose **Recover** to finish from saved checkpoints or **Delete…** to discard it. Captured dictation audio also appears here if both recognition paths fail. An intentional **Escape** cancellation discards the unfinished attempt. A completed session folder contains its Markdown and JSON transcript, session metadata, and any notes and retained audio.

Clean installs use `~/Prosody` or an existing `~/Clippy`. Import preferences to restore custom output folders and labels from older builds. Back up each output folder with its session folders intact. Prosody retains the internal support location at `~/Library/Application Support/Clippy`, or the previous sandbox location at `~/Library/Containers/com.openai.clippy/Data/Library/Application Support/Clippy` when present. The old sandbox output folder can be `~/Library/Containers/com.openai.clippy/Data/Clippy`. Keychain credentials, macOS permissions, login items, and the CLI installation are managed on each Mac.

macOS may ask for Microphone, Screen Recording, or Accessibility permission again when Prosody’s signature changes. After moving or restoring folders, choose them again in **Settings → Output** or in the label editor.

For help, use the project issue tracker. Include the Prosody version and build, macOS version, and steps to reproduce. Use disposable examples and redact personal data. For vulnerabilities, see the [security policy](../SECURITY.md). The source and assets remain all rights reserved under [LICENSE](../LICENSE).
