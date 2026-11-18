# Releasing Prosody

Prosody is a public source and binary repository. Public commits, tags, release notes, screenshots, disk images, and attached files must contain no personal identifying information.

## Prepare the release

1. Update `ClippyReleaseLabel`, `CFBundleShortVersionString`, and `CFBundleVersion` in `Resources/Info.plist`.
2. Add a release note under `docs/releases/` and update the README, handbook, and site where the version or installation flow changed.
3. Run `./script/test.sh` and the applicable dictation benchmark.
4. Run `python3 script/privacy_scan.py`. Inspect screenshots, icons, disk images, and binaries separately for local paths, personal names, private content, or credentials.
5. Use the neutral public commit identity `Prosody Maintainers <maintainers@users.noreply.github.com>`.

## Build and package

Use an ad-hoc signature for a public beta when a project-controlled Developer ID identity is unavailable. Never use a certificate whose subject contains a personal name or email address.

```sh
PROSODY_SIGNING_IDENTITY=- PROSODY_BUILD_CONFIGURATION=release ./script/build_and_run.sh --stage
./script/package_dmg.sh
```

The packager verifies the release label, build number, app bundle, signature, third-party notices, mounted image, and SHA-256 file. It refuses an Apple Development signature.

If a Developer ID Application identity becomes available, prioritize Developer ID signing, Hardened Runtime validation, notarization, and stapling. Test a downloaded copy through Gatekeeper before publishing.

## Publish

Create a draft prerelease, upload the DMG and checksum, download both files from GitHub, and compare them with the verified local copies. Publish only after the tag points at the reviewed commit and the privacy scan passes.
