#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# Test files guard their framework imports. SwiftPM can report zero package
# tests with standalone Command Line Tools. A package test failure is fatal.
swift test
swift run ProsodyValidation
