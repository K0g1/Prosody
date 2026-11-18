# macOS permissions

Enable the grants that correspond to the Prosody features you use:

| Feature | System Settings → Privacy & Security |
| --- | --- |
| Record the microphone or use dictation | **Microphone** |
| Record system audio | **Screen & System Audio Recording** |
| Start dictation by shortcut and insert into another app | **Accessibility** |

In **Settings → Dictation**, choose **Enable…** to open Accessibility settings. Enable the Prosody app you intend to use, return to Prosody, and choose **Check Again**. Accessibility supports the configured shortcut and delivery of text to the focused editor.

## Upgrade identity and legacy locations

The public Beta 2 keeps the bundle identifier but uses an ad-hoc signature. macOS may therefore request capture or Accessibility permission again when upgrading from an earlier development-signed build.

The internal support location is also retained. Prosody prefers `~/Library/Containers/com.openai.clippy/Data/Library/Application Support/Clippy` when that sandbox folder exists, and otherwise uses `~/Library/Application Support/Clippy`. Models live under its `Models` folder and recovery data under `Recovery`. Clean installs use `~/Prosody` for output; upgrades keep the saved folder or an existing `~/Clippy`. The old sandbox output folder, when present, is `~/Library/Containers/com.openai.clippy/Data/Clippy`.

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
