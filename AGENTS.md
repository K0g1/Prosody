# Prosody repository safety

This repository is public. Every commit, tag, issue, release note, screenshot,
binary, and attached artifact must remain free of personal identifying
information.

- Never publish a legal name, personal email address, home or user directory,
  local machine name, private repository link, private recording, credentials,
  signing secrets, or raw workstation log.
- Use `Prosody Maintainers <maintainers@users.noreply.github.com>` for public
  commits unless the repository owner explicitly provides another public
  identity.
- Run `python3 script/privacy_scan.py` before every commit and release upload.
  Inspect binary assets and screenshots manually in addition to text scans.
- Do not publish a DMG signed with a certificate whose subject contains a
  personal name or email. Use a project-controlled distribution identity or an
  ad-hoc signature with explicit Gatekeeper instructions.
- Never copy private Git history, tags, credentials, or local build artifacts
  into this repository.
