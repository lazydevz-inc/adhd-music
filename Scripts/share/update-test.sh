#!/bin/zsh
# Local end-to-end check of the website build's automatic update (Sparkle), without touching /Applications,
# the running app or real data:
#   1. two builds of the website app with their own id (app.adhdmusic.mac.updatetest), data folder
#      (the older one unsandboxed like 1.0 build 2, the newer one sandboxed like 1.0.1 on; see also
#      sandbox-update-test.sh for the data move and a sandboxed copy updating itself),
#      ("ADHD Music Update Test"), local feed (http://127.0.0.1:8765) and a throwaway EdDSA key;
#      the older one signed only, the newer one notarized like a release (Scripts/package-share.sh)
#   2. a local feed served with python3 -m http.server
#   3. idle run: the older copy runs from build/update-test/run with --data-dir scratch and --update-soon; it
#      finds the newer build, takes the delta, installs it after 20 quiet seconds and reopens as the newer one
#   4. playing run: a fresh older copy with --autoplay --mute keeps the update waiting while music plays and
#      installs it when the app quits (no reopen)
#   5. Gatekeeper, code signature and staple checks on the updated app; delta and full sizes
# Then it removes the test id's settings, data folder, Sparkle caches and the throwaway key.
#   --reuse       skip step 1 when build/update-test already holds both builds and the feed
#   --full-only   no deltas in the feed: the update comes from the full dmg (the path people take when they are
#                 more than SHARE_MAX_DELTAS builds behind or a delta fails)
set -euo pipefail

root="${0:A:h:h:h}"
work="$root/build/update-test"
id="app.adhdmusic.mac.updatetest"
port=8765
reuse=0
full_only=0
for arg in "$@"; do
  [[ "$arg" == "--reuse" ]] && reuse=1
  [[ "$arg" == "--full-only" ]] && full_only=1
done
sparkle=$("$root/Scripts/share/get-sparkle.sh")
key="$work/keys/updatetest.key"
log() { print -r -- "[$(date +%H:%M:%S)] $*"; }

if (( ! reuse )); then
  rm -rf "$work/a" "$work/b" "$work/feed" "$work/keys"
  mkdir -p "$work/keys" && chmod 700 "$work/keys"
  # A throwaway key: made in the keychain under its own account, copied to a file, then removed from the keychain.
  "$sparkle/bin/generate_keys" --account adhdmusic-updatetest >/dev/null
  "$sparkle/bin/generate_keys" --account adhdmusic-updatetest -x "$key" >/dev/null
  public=$("$sparkle/bin/generate_keys" --account adhdmusic-updatetest -p)
  security delete-generic-password -s "https://sparkle-project.org" -a adhdmusic-updatetest >/dev/null 2>&1 || true
  for v in a b; do
    if [[ $v == a ]]; then version=1.0.1; build=101; else version=1.0.2; build=102; fi
    cat > "$work/env-$v" <<EOF
# Local update test ($v): its own id, data folder, feed and throwaway key. Never handed out.
SHARE_BUNDLE_ID="$id"
SHARE_DATA_FOLDER="ADHD Music Update Test"
SHARE_VERSION="$version"
SHARE_BUILD="$build"
SHARE_SANDBOX="$([[ $v == a ]] && print 0 || print 1)"
SHARE_FEED_URL="http://127.0.0.1:$port/appcast.xml"
SHARE_UPDATES_URL="http://127.0.0.1:$port/"
SHARE_SPARKLE_PUBLIC_KEY="$public"
SHARE_SPARKLE_KEY_FILE="$key"
SHARE_OUT_DIR="$work/$v"
SHARE_UPDATES_DIR="$work/feed"
EOF
    if (( full_only )); then print 'SHARE_MAX_DELTAS="0"' >> "$work/env-$v"; fi
  done
  log "building the older test version (signed, not notarized)"
  SHARE_ENV_EXTRA="$work/env-a" "$root/Scripts/package-share.sh" --skip-notarize > "$work/package-a.log" 2>&1
  log "building the newer test version (notarized)"
  SHARE_ENV_EXTRA="$work/env-b" "$root/Scripts/package-share.sh" > "$work/package-b.log" 2>&1
fi

old_app="$work/a/ADHD Music.app"
feed="$work/feed"
[[ -d "$old_app" && -f "$feed/appcast.xml" ]] || { print -u2 "Missing test builds in $work (run without --reuse)"; exit 1; }
data_folder="$HOME/Library/Application Support/ADHD Music Update Test"
[[ -e "$data_folder" ]] && { print -u2 "$data_folder already exists; remove it first"; exit 1; }

# The test id's settings: never a login item, no system-audio permission question.
defaults write "$id" v2.openAtLogin -bool false
defaults write "$id" v2.pauseForOtherSound -bool false

python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$feed" > "$work/http.log" 2>&1 &
server=$!
cleanup() {
  kill "$server" 2>/dev/null || true
  pkill -f "$work/run/ADHD Music.app/Contents/MacOS/FocusMusic" 2>/dev/null || true
  sleep 1
  defaults delete "$id" >/dev/null 2>&1 || true
  rm -rf "$data_folder" "$HOME/Library/Caches/$id" "$HOME/Library/HTTPStorages/$id" "$HOME/Library/HTTPStorages/$id.binarycookies" \
    "$HOME/Library/Preferences/$id.plist" "$work/data"
}
trap cleanup EXIT
sleep 1

version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist"; }
running() { pgrep -f "$work/run/ADHD Music.app/Contents/MacOS/FocusMusic" || true; }

run_case() { # name, extra launch options...
  local name=$1; shift
  rm -rf "$work/run" "$work/data"
  mkdir -p "$work/run" "$work/data"
  cp -cR "$old_app" "$work/run/"
  : > "$work/http.log"
  log "$name: starting build $(version_of "$work/run/ADHD Music.app")"
  open -n "$work/run/ADHD Music.app" --args --data-dir "$work/data" --update-soon "$@"
}

# Idle: installs by itself after 20 quiet seconds and reopens as the newer build.
run_case idle --mute
first=""
for i in {1..60}; do sleep 2; first=${first:-$(running)}; [[ $(version_of "$work/run/ADHD Music.app") == 102 ]] && break; done
sleep 6
after=$(running)
log "idle: on disk $(version_of "$work/run/ADHD Music.app"), process before ${first:-none}, after ${after:-none}"
grep -E '"GET [^"]+"' "$work/http.log" | sed -E 's/.*"(GET [^"]+)".*/  \1/'
[[ $(version_of "$work/run/ADHD Music.app") == 102 && -n "$after" && "$after" != "$first" ]] || { print -u2 "idle case FAILED"; exit 1; }
updated="$work/updated.app"
rm -rf "$updated"; cp -cR "$work/run/ADHD Music.app" "$updated"
pkill -TERM -f "$work/run/ADHD Music.app/Contents/MacOS/FocusMusic" || true
sleep 3

# Playing: waits while music plays, installs on quit, does not reopen.
rm -rf "$data_folder"
run_case playing --mute --autoplay
for i in {1..30}; do sleep 2; grep -qE 'GET [^ ]*(\.delta|-102\.dmg)' "$work/http.log" && break; done
sleep 30
log "playing: on disk after 30 s of music $(version_of "$work/run/ADHD Music.app") (should still be 101)"
[[ $(version_of "$work/run/ADHD Music.app") == 101 ]] || { print -u2 "playing case installed while playing: FAILED"; exit 1; }
pkill -TERM -f "$work/run/ADHD Music.app/Contents/MacOS/FocusMusic"
for i in {1..30}; do sleep 2; [[ $(version_of "$work/run/ADHD Music.app") == 102 ]] && break; done
sleep 4
log "playing: after quit on disk $(version_of "$work/run/ADHD Music.app"), running: ${$(running):-none}"
[[ $(version_of "$work/run/ADHD Music.app") == 102 && -z "$(running)" ]] || { print -u2 "playing case FAILED"; exit 1; }

log "updated app checks"
codesign --verify --deep --strict "$updated" && print "  codesign: valid"
xcrun stapler validate "$updated" | tail -1 | sed 's/^/  /'
spctl --assess --type execute -vv "$updated" 2>&1 | sed 's/^/  /'
xattr -p com.apple.quarantine "$updated" >/dev/null 2>&1 && print "  quarantine flag: yes" || print "  quarantine flag: none"
for f in "$feed"/*.delta(N) "$feed"/*.dmg(N); do print "  ${f:t}: $(stat -f %z "$f") bytes"; done
log "done"
