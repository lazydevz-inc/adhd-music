#!/bin/bash
# Builds and runs the audio engine checks: offline DSP/mixing checks on FocusRenderCore and a
# real-time AVAudioEngine smoke test with the output muted (mixer volume 0, engine volume 0).
# Exit status is non-zero if any check fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/focus-audio-engine-checks.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx26.0 \
    "$ROOT"/Sources/Audio/*.swift "$ROOT/Tests/AudioEngineChecks.swift" \
    -o "$BUILD_DIR/AudioEngineChecks"

"$BUILD_DIR/AudioEngineChecks" "$ROOT"
