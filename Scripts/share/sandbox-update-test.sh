#!/bin/zsh
# Local end-to-end check of the move to App Sandbox through Sparkle, as the public 1.0 (build 2) will take it:
#   a  1.0.1 (101) built like 1.0 build 2: no sandbox, codesign's default signing rule, data in
#      ~/Library/Application Support/<test folder>, settings in ~/Library/Preferences/<test id>.plist
#   b  1.0.2 (102) sandboxed (SHARE_SANDBOX=1): container, migration manifest, Sparkle launcher service, shared rule
#   c  1.0.3 (103) sandboxed: proves a sandboxed copy can install the next update by itself
# Own id (app.adhdmusic.mac.sandboxupdate), own data folder, local feed on 127.0.0.1:8766, throwaway EdDSA key,
# signed with Developer ID but not notarized (Sparkle checks signatures, not notarization; the release path is
# notarized by package-share.sh as usual). Never touches /Applications, the owner's apps or real data.
#
# Steps: a runs with demo records and a marker setting (language ko) → updates itself to b after 20 quiet seconds →
# b opens sandboxed; `--print-data` must show the records and the setting inside the container → b runs →
# updates itself to c → c opens. The container is left in place (a shell can't remove it without macOS asking).
set -euo pipefail

root="${0:A:h:h:h}"
work="$root/build/sandbox-update-test"
id="app.adhdmusic.mac.sandboxupdate"
folder="ADHD Music Sandbox Update Test"
port=8766
sparkle=$("$root/Scripts/share/get-sparkle.sh")
key="$work/keys/test.key"
log() { print -r -- "[$(date +%H:%M:%S)] $*"; }
fail() { print -u2 "FAILED: $*"; exit 1; }
data_folder="$HOME/Library/Application Support/$folder"
[[ -e "$data_folder" ]] && fail "$data_folder already exists; remove it first"

rm -rf "$work"
mkdir -p "$work/keys" "$work/feed" && chmod 700 "$work/keys"
"$sparkle/bin/generate_keys" --account adhdmusic-sandboxupdate >/dev/null
"$sparkle/bin/generate_keys" --account adhdmusic-sandboxupdate -x "$key" >/dev/null
public=$("$sparkle/bin/generate_keys" --account adhdmusic-sandboxupdate -p)
security delete-generic-password -s "https://sparkle-project.org" -a adhdmusic-sandboxupdate >/dev/null 2>&1 || true

make_env() { # name version build sandbox
  cat > "$work/env-$1" <<EOF
SHARE_BUNDLE_ID="$id"
SHARE_DATA_FOLDER="$folder"
SHARE_VERSION="$2"
SHARE_BUILD="$3"
SHARE_SANDBOX="$4"
SHARE_FEED_URL="http://127.0.0.1:$port/appcast.xml"
SHARE_UPDATES_URL="http://127.0.0.1:$port/"
SHARE_SPARKLE_PUBLIC_KEY="$public"
SHARE_SPARKLE_KEY_FILE="$key"
SHARE_OUT_DIR="$work/$1"
SHARE_UPDATES_DIR="$work/feed"
EOF
}
make_env a 1.0.1 101 0
make_env b 1.0.2 102 1
make_env c 1.0.3 103 1
package() { log "building $1"; SHARE_ENV_EXTRA="$work/env-$1" "$root/Scripts/package-share.sh" --skip-notarize > "$work/package-$1.log" 2>&1 || { tail -20 "$work/package-$1.log" >&2; fail "build $1"; }; }
package a
package b

# The test id never becomes a login item and never asks for the sound permission.
defaults write "$id" v2.openAtLogin -bool false
defaults write "$id" v2.pauseForOtherSound -bool false
defaults write "$id" v2.language ko

python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$work/feed" > "$work/http.log" 2>&1 &
server=$!
run="$work/run/ADHD Music.app"
cleanup() {
  kill "$server" 2>/dev/null || true
  pkill -TERM -f "$run/Contents/MacOS/FocusMusic" 2>/dev/null || true
  sleep 1
  defaults delete "$id" >/dev/null 2>&1 || true
  rm -rf "$data_folder" "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id" "$HOME/Library/HTTPStorages/$id.binarycookies"
}
trap cleanup EXIT
sleep 1

version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$run/Contents/Info.plist"; }
running() { pgrep -f "$run/Contents/MacOS/FocusMusic" || true; }
wait_for_version() { # build, seconds
  local i
  for i in $(seq 1 $(( $2 / 2 ))); do sleep 2; [[ $(version_of) == $1 && -n "$(running)" ]] && return 0; done
  return 1
}
sandboxed() { codesign -d --entitlements - --xml "$run" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' && print yes || print no; }

# 1. a (like 1.0 build 2) with demo records, idle → installs b → b opens.
mkdir -p "$work/run"
cp -cR "$work/a/ADHD Music.app" "$work/run/"
log "a: build $(version_of), sandboxed $(sandboxed)"
open -n "$run" --args --seed-demo --mute --update-soon
sleep 6
first=$(running)
[[ -f "$data_folder/records.json" ]] || fail "a did not write records to $data_folder"
records_size=$(stat -f %z "$data_folder/records.json")
log "a: running ($first), records.json $records_size bytes in Application Support"
wait_for_version 102 120 || fail "a did not update to b (on disk $(version_of))"
sleep 4
second=$(running)
log "b: on disk $(version_of), sandboxed $(sandboxed), process ${second:-none} (was $first)"
[[ -n "$second" && "$second" != "$first" ]] || fail "b did not reopen"
grep -E '"GET [^"]+"' "$work/http.log" | sed -E 's/.*"(GET [^"]+)".*/  \1/'
codesign -d -r- "$run" 2>&1 | grep designated | sed 's/^/  /'

# 2. What b sees: the container, with a's records and settings copied in.
pkill -TERM -f "$run/Contents/MacOS/FocusMusic"; sleep 3
summary=$("$run/Contents/MacOS/FocusMusic" --print-data)
print -r -- "$summary" | sed 's/^/  /'
print -r -- "$summary" | grep -q "Containers/$id/Data" || fail "b does not use its container"
copied=$(print -r -- "$summary" | awk '$1 == "records.json" { print $2 }')
[[ -e "$data_folder/records.json" ]] && records_size=$(stat -f %z "$data_folder/records.json")
log "records.json: ${copied:-missing} bytes in the container, $records_size bytes in Application Support"
[[ -n "$copied" ]] && (( copied * 2 >= records_size )) || fail "records not copied into the container"
print -r -- "$summary" | grep -q "v2.language = ko" || fail "settings not copied into the container"
log "b: records and settings are in the container; Application Support copy left: $([[ -e "$data_folder" ]] && print yes || print no)"

# 3. b (sandboxed) installs c by itself.
package c
: > "$work/http.log"
open -n "$run" --args --mute --update-soon
sleep 4
first=$(running)
wait_for_version 103 150 || fail "b did not update to c (on disk $(version_of))"
sleep 4
second=$(running)
log "c: on disk $(version_of), process ${second:-none} (was $first)"
[[ -n "$second" && "$second" != "$first" ]] || fail "c did not reopen"
grep -E '"GET [^"]+"' "$work/http.log" | sed -E 's/.*"(GET [^"]+)".*/  \1/'
pkill -TERM -f "$run/Contents/MacOS/FocusMusic"; sleep 3
"$run/Contents/MacOS/FocusMusic" --print-data | grep -E 'data folder|records.json|language' | sed 's/^/  /'
codesign --verify --deep --strict "$run" && print "  c: codesign valid"
log "done (test container ~/Library/Containers/$id stays; remove it in Finder if wanted)"
