#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift test
# Command Line Tools may omit XCTest and Testing; this executable always runs
# the real service and lifecycle checks, regardless of framework availability.
swift run ProsodyValidation
