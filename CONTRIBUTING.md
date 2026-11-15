# Contributing to Prosody

Coordinate changes with the project maintainers and see [LICENSE](LICENSE) for terms.

1. Start a focused branch and describe the behavior you want to change.
2. Follow the [development guide](docs/DEVELOPMENT.md). Run `./script/test.sh` with Xcode selected and add a targeted regression check when it can reproduce the problem.
3. Test macOS behavior in a staged app when changing capture, permissions, keyboard input, or window controls. For UI work, use demo data and attach screenshots if they explain the change.
4. In your pull request, explain the user-visible change, how you verified it, and any effect on permissions, saved data, performance, or supported macOS versions.

Keep recordings, private transcripts, model weights, credentials, and raw audit output out of the repository. See [SECURITY.md](SECURITY.md) for confidential reports.
