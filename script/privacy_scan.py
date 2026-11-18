#!/usr/bin/env python3
"""Reject common personal-data and credential leaks in tracked public files."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


PATTERNS = {
    "absolute home path": re.compile(r"/Users/[^/\s]+/"),
    "mounted volume path": re.compile(r"/Volumes/[^/\s]+/"),
    "temporary private path": re.compile(r"/private/var/"),
    "private repository link": re.compile(r"github\.com/K0g1/Clippy", re.IGNORECASE),
    "private key": re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
    "GitHub token": re.compile(r"(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+"),
    "email address": re.compile(
        r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
    ),
}

APPROVED_EMAILS = {
    "maintainers@users.noreply.github.com",
    "user@example.com",
    "password@example.com",
}


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
    )
    return [Path(item.decode()) for item in result.stdout.split(b"\0") if item]


def main() -> int:
    findings: list[str] = []
    for path in tracked_files():
        if path == Path(__file__).resolve().relative_to(Path.cwd().resolve()):
            continue
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data[:4096]:
            continue
        text = data.decode("utf-8", errors="replace")
        for line_number, line in enumerate(text.splitlines(), 1):
            for label, pattern in PATTERNS.items():
                for match in pattern.finditer(line):
                    if label == "email address" and match.group(0) in APPROVED_EMAILS:
                        continue
                    if label == "email address" and match.group(0).lower().endswith(
                        (".png", ".jpg", ".jpeg", ".icns", ".svg", ".pdf")
                    ):
                        continue
                    findings.append(f"{path}:{line_number}: {label}")

    if findings:
        print("Privacy scan failed:", file=sys.stderr)
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("Privacy scan: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
