#!/usr/bin/env python3
"""Reject common personal-data and credential leaks in tracked public files."""

from __future__ import annotations

import codecs
import os
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
    "API key": re.compile(r"(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"),
    "Google API key": re.compile(r"(?<![A-Za-z0-9_-])AIza[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])"),
    "AWS access key ID": re.compile(r"(?<![A-Za-z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"),
    "email address": re.compile(
        r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
    ),
}

APPROVED_EMAILS = {
    "maintainers@users.noreply.github.com",
    "user@example.com",
    "password@example.com",
}


def git(directory: Path, *args: str) -> bytes:
    return subprocess.run(
        ["git", *args],
        cwd=directory,
        check=True,
        capture_output=True,
    ).stdout


def git_paths(directory: Path, *args: str) -> set[Path]:
    return {Path(os.fsdecode(item)) for item in git(directory, *args).split(b"\0") if item}


def decode_text(data: bytes) -> str:
    if data.startswith((codecs.BOM_UTF32_LE, codecs.BOM_UTF32_BE)):
        return data.decode("utf-32", errors="replace")
    if data.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        return data.decode("utf-16", errors="replace")
    sample = data[:4096]
    if b"\0" not in sample:
        return data.decode("utf-8", errors="replace")
    # BOM-less UTF-16 with predominantly ASCII text has most of its NULs
    # in one byte lane. Keep skipping ordinary binary assets.
    for encoding, null_lane, text_lane in (
        ("utf-16-le", sample[1::2], sample[::2]),
        ("utf-16-be", sample[::2], sample[1::2]),
    ):
        if null_lane.count(0) > len(null_lane) / 2 and text_lane.count(0) <= len(text_lane) / 10:
            return data.decode(encoding, errors="replace")
    return ""


def worktree_data(root: Path, relative_path: Path) -> bytes | None:
    path = root / relative_path
    if path.parent.resolve() != path.parent:
        raise OSError("A scanned path has a symlinked parent")
    if path.is_symlink():
        return os.fsencode(os.readlink(path))
    return path.read_bytes() if path.is_file() else None


def scan(data: bytes, path_label: str, findings: list[str]) -> None:
    for line_number, line in enumerate(decode_text(data).splitlines(), 1):
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(line):
                if label == "email address" and match.group(0) in APPROVED_EMAILS:
                    continue
                if label == "email address" and match.group(0).lower().endswith(
                    (".png", ".jpg", ".jpeg", ".icns", ".svg", ".pdf")
                ):
                    continue
                findings.append(f"{path_label}:{line_number}: {label}")


def main() -> int:
    scanner = Path(__file__).resolve()
    findings: list[str] = []
    try:
        root = Path(os.fsdecode(git(scanner.parent, "rev-parse", "--show-toplevel")).removesuffix("\n")).resolve()
        tracked = git_paths(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
        staged = git_paths(root, "diff", "--cached", "--name-only", "--diff-filter=ACMRT", "-z")
        for path in sorted((tracked | staged) - {scanner.relative_to(root)}):
            data = worktree_data(root, path)
            if data is not None:
                scan(data, str(path), findings)
            if path in staged:
                # The index can still contain content removed from the file
                # after staging, including when the working file was deleted.
                indexed = git(root, "show", f":{path}")
                if indexed != data:
                    scan(indexed, f"{path} (staged)", findings)
    except (OSError, ValueError, subprocess.CalledProcessError):
        print("Privacy scan could not read the checkout or its Git index.", file=sys.stderr)
        return 1

    if findings:
        print("Privacy scan failed:", file=sys.stderr)
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("Privacy scan: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
