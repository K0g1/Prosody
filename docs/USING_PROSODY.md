# Using Prosody

Prosody opens in the macOS menu bar. Click its icon for the recorder, or Control-click it for quick actions. **Settings** and **Transcripts** open in separate windows. Use **View → Enter Full Screen** or **Control-Command-F** in either window.

This Markdown guide is the current reference for setup, recording, dictation, transcripts, and privacy.

## Set up and record

1. Open **Settings → Models** and click **Download** next to **Parakeet Unified**. The model recognizes English on your Mac after the initial download.
2. Open **Settings → Audio**. Choose **System Audio**, **Microphone**, or **System + Mic** (the default), then click **Request Permissions**. See [macOS permissions](PERMISSIONS.md) if a grant does not take effect.
3. In the menu bar recorder, choose **Audio** and optionally enter a title, select labels, and check **Save to**.
4. Click **Start Recording**. Use **Pause** and **Resume** to skip a portion. Click **Finish**, then **View** in the saved notice or open **Transcripts** from the recorder footer.

**Settings → Audio → Keep original audio** is off by default. Turn it on for playback of subsequent sessions. **Settings → Transcription → Live transcription** is on by default; turn it off to transcribe after finishing. Under **Transcript layout**, **Maximum words per block** defaults to 40 (range 10–100), and **Pause before new block** defaults to 1.5 seconds (range 0.5–5). Changes apply to the next recording, import, recovery, or dictation.

The global recording shortcut is **Option-Command-R** by default. It starts, pauses, or resumes capture. Change it under **Settings → General → Global recording shortcut**. To finish, use the recorder.

## Dictate into another app

Open **Settings → Dictation → Enable…**, allow Accessibility access for Prosody, then return and click **Check Again** if shown. Allow microphone access when prompted.

Click a text field. Hold **Right Command**, speak, and release it. Press the shortcut again for the next utterance while the previous result is still being prepared or delivered. A small queue preserves release order; if it fills, let an earlier result finish before trying again. Keep the intended field focused.

- **Escape** cancels unfinished dictation. A quick tap or silence creates no output.
- In **Settings → Dictation**, change **Shortcut**, switch **Activation** from **Hold to talk** to **Press to start / stop**, or choose the waveform-only **Minimal** pop-up.
- **Standard paste** is the default. Try **Keyboard typing** if the editor rejects paste. If Prosody cannot safely insert into the original destination, use **Copy Text** when offered. To keep the result on the clipboard, turn on **Copy output to clipboard**.
- Completed dictations are saved. Open **Transcripts** and turn on **Include Dictation** to see them; the checkbox starts off.

## Read, play, and export transcripts

Open **Transcripts** from the menu bar recorder. The sidebar searches titles and labels. Use the **Label** filter and sort by newest, oldest, recording name, longest, shortest, or label. **With retained audio** and **Without retained audio** are both checked by default; one can be cleared, but the app will not let you clear both. Use the search field in the reader to find spoken text or speaker names within the selected transcript.

For a session with retained audio, click **Play**, click a timestamp to jump to that passage, or drag the timeline to scrub. The skip controls move five seconds at a time. **Following** highlights the passage at the playback position and scrolls to it. Manual scrolling or searching suspends follow; click **Follow Audio** to resume and return to playback. While a search is active, **Follow Audio** is disabled until the query is cleared. Reading, search, and copy work without retained audio.

The timeline shows where speech occurs, skips duplicate echo text, and leaves trailing silence blank after the last visible speech time. Long sessions load audio as needed for playback. Closing the transcript window stops playback.

**Copy Raw** copies speech with a blank line between blocks and omits timestamps and speaker names. **Copy Markdown** includes transcript formatting. Open **More Transcript Actions** (the ellipsis) for **Rename Speakers**, **Regenerate Notes**, **Open Notes**, or **Reveal in Finder**.

To import audio, choose **Transcripts → Transcribe Audio File…** and select one audio file. Turn on **Keep original audio** before importing to retain a playable copy.

## Labels and folders

Open **Settings → Labels → Add Label**, or select an existing label. Set the name and color, then use **Naming → File naming pattern** and **Date format**. Use **Preview** to check the resulting title and Markdown filename. In **Saving destination**, use **Choose Folder…** or **Use Default Folder**. Select **Create Label** or **Save Changes** to apply the draft. Drafts stay in Settings as you switch labels or sections. Select **Discard Changes** to restore an existing label or **Cancel** to drop a new draft.

Before recording, open **Labels** in the recorder and select one or more. The first selected label is primary. Use **Make Primary** to change it. The primary label sets the title and filename pattern and can override the default output folder. To update a saved transcript's labels, open it and choose **Labels → Save Labels** after editing the selection. This updates its labels without moving or renaming the files.

## Appearance, tray, notes, and privacy

- **Settings → Appearance** offers 91 themes in seven groups; Beta 1 adds 55. **Graphite** is the default. **Frosted Glass** follows the system appearance and respects **Reduce Transparency**.
- **Settings → Tray Elements** controls which optional items appear in the compact recorder. Hiding an item keeps its saved choice. **Show All Controls** restores all optional items.
- **Settings → General → Launch Prosody at Login** is off by default. Use **Open Login Items…** if macOS needs you to approve it.
- **Settings → Replacements → Add Replacement** applies literal, case-insensitive whole words or phrases to future transcriptions. Leave **Replace with** blank to remove a match.
- **Settings → Speakers → Speaker differentiation** defaults to **Basic**, which separates microphone and system audio. **Full** attempts a separate speaker pass after transcription and may download another model.

**Settings → Notes** defaults to automatic notes with **Offline Outline**, which formats the transcript locally. Dictation does not generate notes automatically. To use a server for notes, choose a provider and its model, then check **Test Connection**. **Settings → General → Local-only mode** is on by default. If you turn it off and choose a remote provider, notes requests send transcript text and context such as speaker names and timestamps. Audio capture and speech recognition still run on your Mac. Provider credentials stay in the macOS Keychain. See the [third-party notices](../Resources/ThirdPartyNotices/README.md).

## Recovery, upgrade, and backup

After an interruption, open the recorder. If you see **Unfinished recording**, choose **Recover** to finish from saved checkpoints or **Delete…** to discard it. A completed session folder contains its Markdown and JSON transcript, session metadata, and any notes and retained audio.

Clean installs use `~/Prosody`; upgrades keep the saved folder or an existing `~/Clippy`. Back up every output folder, including label destinations, with the session folders intact. Prosody retains the internal support location at `~/Library/Application Support/Clippy`, or the previous sandbox location at `~/Library/Containers/com.openai.clippy/Data/Library/Application Support/Clippy` when present. The old sandbox output folder can be `~/Library/Containers/com.openai.clippy/Data/Clippy`. App preferences and Keychain credentials are stored separately by macOS.

Distributed builds may retain the bundle identifier and signing identity for upgrades. This source snapshot does not include a signed binary. After moving or restoring folders, choose them again in **Settings → Output** or in the label editor.

This source snapshot does not include a signed installer or notarized build.

For help, use the project issue tracker. Include the Prosody version and build, macOS version, and steps to reproduce. Use disposable examples and redact personal data. For vulnerabilities, see the [security policy](../SECURITY.md). The source and assets remain all rights reserved under [LICENSE](../LICENSE).
