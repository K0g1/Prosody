# Releasing Prosody

Prosody is a public source and binary repository. Public commits, tags, release notes, screenshots, disk images, and attached files must contain no personal identifying information.

## Prepare the release

1. Update `ClippyReleaseLabel` and `CFBundleShortVersionString` as needed. Increase `CFBundleVersion` in `Resources/Info.plist` for every distributable build, including a rebuild of the same beta.
2. Add a release note under `docs/releases/` and update the README, handbook, and site where the version or installation flow changed.
3. Run `./script/test.sh` and the applicable dictation benchmark.
4. Run `python3 script/privacy_scan.py`. Inspect screenshots, icons, disk images, and binaries separately for local paths, personal names, private content, or credentials.
5. Use the neutral public commit identity `Prosody Maintainers <maintainers@users.noreply.github.com>`.

## Build and package

Use an ad-hoc signature for a public beta when a project-controlled Developer ID identity is unavailable. Never use a certificate whose subject contains a personal name or email address.

```sh
PROSODY_SIGNING_IDENTITY=- PROSODY_BUILD_CONFIGURATION=release ./script/build_and_run.sh --stage
./script/package_dmg.sh
./script/prepare_appcast.sh
```

The packager verifies the release label, build number, app bundle, signature, third-party notices, mounted image, and SHA-256 file. It refuses an Apple Development signature.

If a Developer ID Application identity becomes available, prioritize Developer ID signing, Hardened Runtime validation, notarization, and stapling. Test a downloaded copy through Gatekeeper before publishing.

The appcast script uses the Sparkle keychain account `org.prosody.official-updates`. Keep its private EdDSA key in the project’s release keychain and securely back it up outside the repository. The public key in `Resources/Info.plist` identifies the trusted signer. Verify that the prepared item points to the exact DMG bytes you will upload. Do not edit the generated XML after signing. [Sparkle publishing guide](https://sparkle-project.org/documentation/publishing/)

## Publish

Create a draft prerelease and upload the DMG, checksum, and signed `appcast.xml`. Download all three assets and compare them with the verified local copies before publishing. The Pages workflow serves the appcast from the most recently published release that includes one. After publishing, run **Deploy Prosody site** on `main` and confirm the served feed matches the release asset. Test that an older updater-enabled build installs the update and relaunches with its saved preferences.
