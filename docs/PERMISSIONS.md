# macOS permissions

Enable the grants that correspond to the Prosody features you use:

| Feature | System Settings → Privacy & Security |
| --- | --- |
| Record the microphone or use dictation | **Microphone** |
| Record system audio | **Screen & System Audio Recording** |
| Start dictation by shortcut and insert into another app | **Accessibility** |

In **Settings → Dictation**, choose **Enable…** to open Accessibility settings. Enable the Prosody app you intend to use and return to Prosody. **Shortcut ready** confirms the event monitor is active. Use **Allow Microphone…** if the microphone still needs permission. Microphone-only recordings and dictation use the same audio-only capture path.

## Upgrade identity and legacy locations

The public beta keeps the bundle identifier and uses an ad-hoc signature. macOS may request capture or Accessibility permission again when the signature changes, including after an in-app update.

Prosody prefers `~/Library/Containers/com.openai.clippy/Data/Library/Application Support/Clippy` when that sandbox folder exists. It otherwise uses `~/Library/Application Support/Clippy`. Models live under `Models` and recovery data under `Recovery`. Choose **Settings → General → Import Preferences…** to restore previously configured output folders. Prosody uses `~/Prosody` or an existing `~/Clippy` as its default.

An upgrade does not move or delete saved recordings. Back up every output folder before replacing an app, and keep the previous distributed build until you have checked the new app.

## If a permission is enabled but capture still fails

macOS tracks permission grants by app identity. Use the installed copy in **Applications** for normal use, or the exact staged `dist/Prosody.app` when developing. Keeping multiple copies or switching signing identities can cause macOS to prompt again.

1. Quit Prosody and any old Clippy copy.
2. In **System Settings → Privacy & Security**, remove a stale entry for an older copy or signing identity, then enable the current app in the required pane. If macOS asks you to quit and reopen, do so.
3. Retry capture or return to **Settings → Dictation → Check Again**.

For local development, use a consistent Apple Development identity where available. An ad-hoc signature can require regranting permissions after each rebuild. To inspect the staged bundle:

```sh
codesign -d -r- dist/Prosody.app
codesign --verify --deep --strict dist/Prosody.app
```

Distribution signing and notarization are separate from capture permissions. See [Build from source](../README.md#build-from-source) and [Releasing Prosody](RELEASING.md).
