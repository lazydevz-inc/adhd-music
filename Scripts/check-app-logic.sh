#!/bin/zsh
# Compiles the model layer (no UI, no audio engine) with Tests/AppLogicChecks.swift and runs it.
set -euo pipefail
root="${0:A:h:h}"
out="${TMPDIR:-/tmp}/focus-app-logic-checks"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx26.0 \
  "$root/Sources/App/Basics.swift" "$root/Sources/App/Strings.swift" "$root/Sources/App/Library.swift" "$root/Sources/App/Ledger.swift" \
  "$root/Tests/AppLogicChecks.swift" -o "$out"
"$out"
