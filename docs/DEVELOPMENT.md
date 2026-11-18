# Developing Prosody

Use macOS 15 or later, Swift 6, and Xcode with its toolchain selected. Apple silicon is the tested configuration for Parakeet. The app bundle uses Xcode’s App Intents extractor during staging. SwiftPM resolves the pinned FluidAudio revision in [Package.resolved](../Package.resolved); downloaded model files stay outside the repository.

The coordinated beta rename uses `ProsodyCore`, `ProsodyApp`, and `ProsodyValidation`. Their source paths are `Sources/ProsodyCore`, `Sources/ProsodyApp`, and `Tools/ProsodyValidation`. New commands use `PROSODY_*` environment names; `CLIPPY_*` remains a compatibility alias. The bundle identifier remains `com.openai.clippy`, and `ClippyReleaseLabel` remains a compatibility plist key.

## Build and run

| Command | Purpose |
| --- | --- |
| `./script/build_and_run.sh` | Build, sign, and launch the debug app |
| `./script/build_and_run.sh --release` | Build, sign, and launch the optimized app |
| `PROSODY_BUILD_CONFIGURATION=release ./script/build_and_run.sh --stage` | Stage an optimized app in `dist/Prosody.app` without launching or stopping Prosody |
| `./script/build_and_run.sh --verify` | Launch and check that the app process starts |
| `./script/build_and_run.sh --request-permissions` | Open the setup window and request capture grants |
| `./script/build_and_run.sh --logs` | Launch and stream logs for the Prosody process |
| `./script/build_and_run.sh --telemetry` | Launch and stream the Prosody log subsystem |
| `./script/build_and_run.sh --debug` | Stage the app and start LLDB |
| `./script/test.sh` | Run package tests and standalone service checks |

Launch and debugger modes stop a running process named Prosody first. Use `--stage` to build alongside an installed copy without interrupting it. Set `PROSODY_DIST_DIR` to put staged output somewhere other than `dist/`. The compatibility alias is `CLIPPY_DIST_DIR`.

A normal launch opens only the menu-bar item. Settings and Transcripts open on request and use native window controls. The Settings window has a fixed layout; the library remembers its geometry. The separate recorder window is available for QA with `PROSODY_SHOW_CONTROLS=1` or the app's `--show-controls` argument. `CLIPPY_SHOW_CONTROLS` remains a compatibility alias.

## Signing and permissions

The script prefers the first available Apple Development identity. Override it explicitly with `PROSODY_SIGNING_IDENTITY` when selecting a particular keychain identity:

```sh
security find-identity -p codesigning -v
PROSODY_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./script/build_and_run.sh --stage
```

Use a consistent local Apple Development identity for development. Public releases use a project-safe ad-hoc or Developer ID signature and never publish a certificate that contains a personal name. Ad-hoc signing can require regranting permissions after a rebuild. See [permission troubleshooting](PERMISSIONS.md).

## Demo mode and testing

Run `./script/test.sh` with Xcode selected. It combines the Swift package tests and standalone service checks and does not require installed models. The executable is `ProsodyValidation`. See the [release validation guide](release-validation.md).

For changes that affect inference, run the local dictation benchmark with the installed Parakeet model. Capture, insertion, and window behavior also need native checks; use the [release validation guide](release-validation.md). A passing package test is not evidence that a physical microphone, a real shortcut, or a native editor accepted the change.

Use `PROSODY_DEMO_MODE=1` or `--demo` to seed sample sessions and isolate preferences, history, and output. Add `PROSODY_SHOW_CONTROLS=1` for the separate debug recorder window when needed. `CLIPPY_DEMO_MODE` and `CLIPPY_SHOW_CONTROLS` remain compatibility aliases. Demo mode does not exercise real capture permissions by default. Use disposable files and editors for native tests. Release builds exclude the debug dictation and hardware fixtures.

When adding a Settings control, use the page's search metadata and a stable control identifier. Put a short explanation in contextual help if the control needs one. Check that the result opens the correct section and scrolls to the control. For appearance changes, verify contrast, light and dark appearance, and Reduce Transparency. Review the recorder, Settings, Transcripts, and dictation overlay.

Keep source and documentation free of private sessions, credentials, raw logs, and local machine paths. Record release checks in the [validation guide](release-validation.md); publish only sanitized media.

Run an isolated real model download, inference, and deletion check with
`swift run ProsodyValidation --model-smoke MODEL_ID FIXTURE.aiff`. Use a generated
audio file and one of `parakeet-unified`, `parakeet-v3`, or `fluid-speech-pro`.
The command uses a temporary cache.

The CLI and the app share the versioned transport in `Sources/ProsodyIPC`.
Keep the help output and [CLI skill](skills/prosody-cli/SKILL.md) in sync when adding flags.
