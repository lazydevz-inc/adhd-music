#!/bin/zsh
# Makes the free build people download: builds dist/share/<name>.app (Scripts/build-app.sh --share),
# gets it notarized and stapled, and wraps it in the designed dmg. Result: dist/share/<Name>-<version>.dmg
#
# Notarization, two ways:
#   1. A notarytool keychain profile (SHARE_NOTARY_PROFILE in Scripts/share/share.env), made once with
#        xcrun notarytool store-credentials "<your profile name>" --team-id <YOUR_TEAM_ID>
#      Then the app AND the dmg are notarized and stapled.
#   2. Otherwise Xcode's signed-in developer account (Xcode › Settings › Apple Accounts, your team):
#      the app goes up through `xcodebuild -exportArchive` (destination upload) and comes back stapled via
#      `xcodebuild -exportNotarizedApp`. No password or code needed. The dmg itself is then signed but not
#      notarized; a downloaded (quarantined) copy still opens without a warning on macOS 26.2 (tested),
#      and Gatekeeper checks the stapled app when it first opens.
#   --allow-missing-noise   pass-through for a local test without the shared noise loops (never hand it out)
#   --skip-notarize         local test only: signed, not notarized (and kept out of the update feed)
#   --replace-build         make SHARE_BUILD again although the feed already lists it (only if it was never online)
#
# Automatic updates (Sparkle, website build only): the dmg is also the full update. It is copied into
# dist/share/updates/ as <Name>-<version>-<build>.dmg, and Sparkle's generate_appcast signs it with the EdDSA key
# (login keychain, account SHARE_SPARKLE_ACCOUNT; if macOS asks, Always Allow), makes deltas
# to it from up to SHARE_MAX_DELTAS earlier builds kept in that folder, and writes a signed appcast.xml.
# What goes online is printed at the end: appcast.xml at SHARE_FEED_URL, the new dmg and its deltas under
# SHARE_UPDATES_URL. Keep the older dmgs in dist/share/updates (they need not be online): the next release's
# deltas are made from them. Each release: raise SHARE_BUILD in share.env first.
set -euo pipefail

root="${0:A:h:h}"
source "$root/Scripts/share/share.env"
build_args=(--share)
skip_notarize=0
replace_build=0
for arg in "$@"; do
  [[ "$arg" == "--allow-missing-noise" ]] && build_args+=(--allow-missing-noise)
  [[ "$arg" == "--skip-notarize" ]] && skip_notarize=1
  [[ "$arg" == "--replace-build" ]] && replace_build=1
done

# The update feed is signed with your own Sparkle EdDSA key (share.env ships with a placeholder account).
if [[ "$SHARE_SPARKLE_ACCOUNT" == YOUR_* && -z "${SHARE_SPARKLE_KEY_FILE:-}" ]]; then
  print -u2 "Scripts/share/share.env still has the placeholder SHARE_SPARKLE_ACCOUNT. Make your own key with"
  print -u2 "  build/vendor/Sparkle-<version>/bin/generate_keys --account <name>"
  print -u2 "and put that account name and the public key it prints (SHARE_SPARKLE_PUBLIC_KEY) in share.env."
  exit 1
fi

out="${SHARE_OUT_DIR:-$root/dist/share}"
updates="${SHARE_UPDATES_DIR:-$out/updates}"
sparkle=$("$root/Scripts/share/get-sparkle.sh")
# A build number already in the feed may already be on people's Macs: refuse before spending a build on it.
if [[ -f "$updates/appcast.xml" ]] && grep -q "<sparkle:version>$SHARE_BUILD</sparkle:version>" "$updates/appcast.xml" \
   && (( ! replace_build )) && ! (( skip_notarize )); then
  print -u2 "Build $SHARE_BUILD is already in $updates/appcast.xml. Raise SHARE_BUILD in Scripts/share/share.env."
  print -u2 "(If build $SHARE_BUILD was never put online, run again with --replace-build.)"
  exit 1
fi

app=$("$root/Scripts/build-app.sh" "${build_args[@]}" | tail -1)
dmg="$out/${SHARE_NAME// /-}-$SHARE_VERSION.dmg"

profile=0
if xcrun notarytool history --keychain-profile "$SHARE_NOTARY_PROFILE" >/dev/null 2>&1; then profile=1; fi

notarize() { # path
  xcrun notarytool submit "$1" --keychain-profile "$SHARE_NOTARY_PROFILE" --wait --timeout 60m | tee "$out/notary-$(basename "$1").log"
  grep -q "status: Accepted" "$out/notary-$(basename "$1").log"
}

if (( skip_notarize )); then
  print -u2 "Skipping notarization (local test only)."
elif (( profile )); then
  zip="$out/${SHARE_NAME// /-}-app.zip"
  ditto -c -k --keepParent "$app" "$zip"
  notarize "$zip"
  rm -f "$zip"
  xcrun stapler staple "$app"
else
  # Xcode route: wrap the signed app in an archive, upload it, wait, take back the stapled copy.
  work="$root/build/xcarchive"
  archive="$work/$SHARE_NAME.xcarchive"
  rm -rf "$work" "$root/build/xcexport"
  mkdir -p "$archive/Products/Applications"
  ditto "$app" "$archive/Products/Applications/$(basename "$app")"
  /usr/bin/python3 -I - "$archive/Info.plist" "$work/ExportOptions.plist" "$(basename "$app")" "$SHARE_BUNDLE_ID" \
    "$SHARE_VERSION" "$SHARE_BUILD" "$SHARE_SIGN_IDENTITY" "$SHARE_NAME" <<'PY'
import plistlib, sys, datetime
info, opts, app, bid, ver, build, ident, name = sys.argv[1:9]
team = ident.rsplit("(", 1)[1].rstrip(")")
plistlib.dump({"ApplicationProperties": {"ApplicationPath": "Applications/" + app, "Architectures": ["arm64"],
               "CFBundleIdentifier": bid, "CFBundleShortVersionString": ver, "CFBundleVersion": build,
               "SigningIdentity": ident, "Team": team},
               "ArchiveVersion": 2, "CreationDate": datetime.datetime.now(), "Name": name, "SchemeName": name},
              open(info, "wb"))
plistlib.dump({"method": "developer-id", "destination": "upload", "teamID": team,
               "signingStyle": "manual", "signingCertificate": "Developer ID Application"}, open(opts, "wb"))
PY
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
    -exportPath "$root/build/xcexport" -allowProvisioningUpdates > "$work/upload.log" 2>&1 \
    || { tail -20 "$work/upload.log" >&2; exit 1; }
  print -u2 "Uploaded for notarization; waiting for Apple…"
  for try in {1..80}; do
    if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$root/build/xcexport" > "$work/notarized.log" 2>&1; then
      break
    fi
    (( try == 80 )) && { tail -20 "$work/notarized.log" >&2; exit 1; }
    sleep 30
  done
  app="$root/build/xcexport/$(basename "$app")"
  xcrun stapler validate "$app"
fi

rm -f "$dmg"
# dmgbuild 1.6.5 + ds_store 1.3.1 + mac_alias 2.2.2 (MIT) in build/.venv-dmg:
#   /usr/bin/python3 -m venv build/.venv-dmg && build/.venv-dmg/bin/pip install dmgbuild==1.6.5 ds_store==1.3.1 mac_alias==2.2.2
# run through Scripts/share/dmgbuild_tahoe.py, which applies the macOS 26.2 background fix.
dmgpy="$root/build/.venv-dmg/bin/python"
if [[ -x "$dmgpy" ]] && "$dmgpy" -c "import dmgbuild" 2>/dev/null; then
  # The designed window: background, icon places, no toolbar, app icon on the disk.
  bg="$root/build/dmg"
  mkdir -p "$bg"
  swift "$root/Scripts/share/dmg_background.swift" "$bg/background.png" 1 "$SHARE_NAME"
  swift "$root/Scripts/share/dmg_background.swift" "$bg/background@2x.png" 2 "$SHARE_NAME"
  tiffutil -cathidpicheck "$bg/background.png" "$bg/background@2x.png" -out "$bg/background.tiff" >/dev/null
  "$dmgpy" "$root/Scripts/share/dmgbuild_tahoe.py" -s "$root/Scripts/share/dmg_settings.py" -D app="$app" -D background="$bg/background.tiff" \
    -D icon="$app/Contents/Resources/AppIcon.icns" "$SHARE_NAME" "$dmg"
else
  print -u2 "dmgbuild is not set up (build/.venv-dmg): making a plain dmg without the designed window."
  stage=$(mktemp -d "${TMPDIR:-/tmp}/focus-share-dmg.XXXXXX")
  ditto "$app" "$stage/$(basename "$app")"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "$SHARE_NAME" -srcfolder "$stage" -fs APFS -format ULFO -ov "$dmg" >/dev/null
  rm -rf "$stage"
fi
/usr/bin/codesign --force --timestamp --sign "$SHARE_SIGN_IDENTITY" "$dmg"

if (( profile )) && (( ! skip_notarize )); then
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
spctl --assess --type execute -vv "$app" || (( skip_notarize ))

# The update feed. A local test (--skip-notarize) only gets one when it names its own folder (SHARE_UPDATES_DIR).
if (( skip_notarize )) && [[ -z "${SHARE_UPDATES_DIR:-}" ]]; then
  print -u2 "Not notarized: left out of the update feed."
else
  mkdir -p "$updates"
  update="$updates/${SHARE_NAME// /-}-$SHARE_VERSION-$SHARE_BUILD.dmg"
  if [[ -e "$update" ]]; then
    # Same build again (--replace-build): its old dmg and the deltas made to it would no longer match.
    rm -f "$update" "$updates/$SHARE_NAME$SHARE_BUILD-"*.delta(N)
  fi
  cp -c "$dmg" "$update"
  key_args=(--account "$SHARE_SPARKLE_ACCOUNT")
  # Local update tests sign with a throwaway key file instead of the real key.
  [[ -n "${SHARE_SPARKLE_KEY_FILE:-}" ]] && key_args=(--ed-key-file "$SHARE_SPARKLE_KEY_FILE")
  # --maximum-versions 1: the feed lists only the newest build (per minimum macOS), with its deltas.
  "$sparkle/bin/generate_appcast" "${key_args[@]}" --download-url-prefix "$SHARE_UPDATES_URL" \
    --maximum-deltas "$SHARE_MAX_DELTAS" --maximum-versions 1 --auto-prune-update-files "$updates"
  feed="$updates/${SHARE_FEED_URL:t}"
  grep -q "<sparkle:version>$SHARE_BUILD</sparkle:version>" "$feed" || { print -u2 "Build $SHARE_BUILD is not in $feed"; exit 1; }
  # Checked as the app will check it: with the public key in Info.plist, the feed and every file it lists.
  swift "$root/Scripts/share/verify_feed.swift" "$SHARE_SPARKLE_PUBLIC_KEY" "$feed" "$updates" >&2
  print -u2 "Update feed: $feed"
  print -u2 "Put online: ${feed:t} at $SHARE_FEED_URL, and under $SHARE_UPDATES_URL:"
  grep -oE 'url="[^"]+"' "$feed" | sed -E 's/^url="//; s/"$//' | while read -r url; do
    file="$updates/$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1].rsplit("/", 1)[1]))' "$url")"
    print -u2 "  $(basename "$file")  $(stat -f %z "$file") bytes"
  done
fi
print -r -- "$dmg"
