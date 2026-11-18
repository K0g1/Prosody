---
name: prosody-cli
description: Transcribe existing audio files locally through the running macOS Prosody app. Use for Markdown or text exports, saved labels, and correcting recurring recognition errors with persistent replacement rules.
---

# Prosody CLI

Open Prosody, install a speech model in **Settings → Models**, and enable **Settings → General → Enable command-line tool**. Use `prosody` if `~/.local/bin` is on PATH. Otherwise run `~/.local/bin/prosody`. Keep Prosody open until the command returns.

```sh
prosody status [--json]
prosody labels [--json]
prosody transcribe [OPTIONS] AUDIO [AUDIO ...]
prosody replacements list [--json]
prosody replacements set ORIGINAL REPLACEMENT [--json]
prosody replacements remove ORIGINAL [--json]
```

| Option | Effect |
| --- | --- |
| `-o`, `--output-dir PATH` | Save to PATH. Default order is the label's Transcript Copies folder, label's recording folder, then Prosody's default output folder. |
| `-l`, `--label NAME\|UUID` | Apply a saved label. Use `prosody labels --json` for its ID. Defaults to the selected primary label. |
| `-f`, `--format markdown\|plain-markdown\|text` | Write formatted Markdown, text-only Markdown, or raw text. Defaults to the label's copy format or formatted Markdown. |
| `--title TEXT` | Set the title for one input file. |
| `--keep-filename` | Use the audio's basename for the output filename. This is the default. |
| `--label-filenames` | Apply the selected label's naming pattern. |
| `--omit-fillers`, `--keep-fillers` | Override the app's filler word setting for this job. |
| `--include FIELDS`, `--exclude FIELDS` | Override a comma-separated list of Markdown fields. Valid names are `title,date,time,duration,audio-name,timestamps,speakers,labels`. Unspecified fields use Settings → Transcript Export. |
| `--stdout` | Return one transcript on stdout. Omit the output directory in this mode. |
| `--json` | Return structured results with per-input output paths, returned text, or errors. |
| `--` | Treat remaining arguments as filenames. |

```sh
prosody transcribe --label "Lab Meeting" --output-dir ./transcripts --include audio-name --json "./Meeting 01.m4a" "./Meeting 02.wav"
prosody transcribe --stdout --format text ./clip.m4a
prosody replacements set "pro sody" "Prosody"
```

Quote paths and phrases containing spaces. Replacements match literal whole words or phrases case-insensitively. Use `''` for a replacement that removes the match. Changes are shared with Settings → Replacements and apply to new dictations, transcriptions, and their exports.

Each file produces its own output. Prosody adds a numeric suffix on filename collisions. A failed input leaves successful outputs available. Exit status is 0 for success, 1 for a job or connection error, and 2 for invalid arguments. JSON can contain successful items alongside errors.
