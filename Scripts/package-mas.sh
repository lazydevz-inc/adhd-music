#!/bin/zsh
# Makes the Mac App Store package: builds dist/mas/<name>.app (Scripts/build-app.sh --mas), signs it for the
# store (Apple Distribution + the Mac App Store provisioning profile + the application and team identifiers),
# wraps it in an installer package signed with the Mac Installer Distribution certificate, and checks it.
# Result: dist/mas/<Name>-<version>-<build>.pkg
#
#   Scripts/package-mas.sh              check the account pieces, build, sign, package, check. Nothing leaves this Mac.
#   Scripts/package-mas.sh --validate   also let App Store Connect validate the package (needs upload credentials)
#   Scripts/package-mas.sh --upload     validate, then upload the package to App Store Connect. An upload uses up
#                                       its build number.
#
# Names, ids and credentials: Scripts/mas/mas.env. One-time account setup: Scripts/mas/README.md.
# No notarization and no dmg here: the store checks and re-signs what it gets.
set -euo pipefail

root="${0:A:h:h}"
source "$root/Scripts/mas/mas.env"
validate=0
upload=0
for arg in "$@"; do
  case "$arg" in
    --validate) validate=1 ;;
    --upload) validate=1; upload=1 ;;
    *) print -u2 "Unknown option: $arg"; exit 2 ;;
  esac
done

team="$MAS_TEAM_ID"
app_id="$team.$MAS_BUNDLE_ID"
profile="$root/$MAS_PROFILE"
missing=()

# 1. The account pieces this Mac needs, before anything is built.
identities=$(/usr/bin/security find-identity -v 2>/dev/null || true)
app_identity=""
for candidate in "$MAS_APP_SIGN_IDENTITY" "3rd Party Mac Developer Application: ${MAS_APP_SIGN_IDENTITY#*: }"; do
  if print -r -- "$identities" | grep -qF "\"$candidate\""; then app_identity="$candidate"; break; fi
done
[[ -n "$app_identity" ]] || missing+=("the certificate \"$MAS_APP_SIGN_IDENTITY\" (type Apple Distribution) with its private key in the login keychain")
print -r -- "$identities" | grep -qF "\"$MAS_INSTALLER_SIGN_IDENTITY\"" \
  || missing+=("the certificate \"$MAS_INSTALLER_SIGN_IDENTITY\" (type Mac Installer Distribution) with its private key")

profile_plist=$(mktemp "${TMPDIR:-/tmp}/mas-profile.XXXXXX")
trap 'rm -f "$profile_plist"' EXIT
if [[ -f "$profile" ]] && /usr/bin/security cms -D -i "$profile" > "$profile_plist" 2>/dev/null; then
  pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$profile_plist" 2>/dev/null || true; }
  [[ "$(pb Entitlements:com.apple.application-identifier)" == "$app_id" ]] \
    || missing+=("a provisioning profile for $app_id (the one at $MAS_PROFILE is for $(pb Entitlements:com.apple.application-identifier))")
  [[ "$(pb Platform:0)" == "OSX" ]] || missing+=("a macOS provisioning profile (the one at $MAS_PROFILE is for $(pb Platform:0))")
  [[ -z "$(pb ProvisionedDevices)" && "$(pb ProvisionsAllDevices)" != "true" ]] \
    || missing+=("a Mac App Store profile (the one at $MAS_PROFILE is a development or Developer ID profile)")
  expires=$(pb ExpirationDate)
  if [[ -n "$expires" ]] && (( $(date -j -f "%a %b %d %T %Z %Y" "$expires" +%s 2>/dev/null || echo 9999999999) < $(date +%s) )); then
    missing+=("a profile that hasn't expired (the one at $MAS_PROFILE expired $expires)")
  fi
else
  missing+=("the Mac App Store provisioning profile for $app_id saved as $MAS_PROFILE")
fi

if (( ${#missing} )); then
  print -u2 "Not ready to package for the Mac App Store yet. Missing:"
  for item in "${missing[@]}"; do print -u2 "  - $item"; done
  print -u2 "How to make them: Scripts/mas/README.md"
  exit 1
fi

# 2. Build (the same as Scripts/build-app.sh --mas), then sign for the store.
app=$("$root/Scripts/build-app.sh" --mas | tail -1)
work="$root/build/mas-package"
rm -rf "$work"
mkdir -p "$work"
entitlements="$work/entitlements.plist"
cp "$root/Scripts/mas/entitlements.plist" "$entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $app_id" \
  -c "Add :com.apple.developer.team-identifier string $team" "$entitlements"
cp "$profile" "$app/Contents/embedded.provisionprofile"
/usr/bin/codesign --force --options runtime --entitlements "$entitlements" --sign "$app_identity" "$app"
/usr/bin/codesign --verify --strict --verbose=2 "$app"

# 3. What App Review and the upload check look at, checked here first.
binary="$app/Contents/MacOS/FocusMusic"
if strings "$binary" | grep -qE 'TCCAccess|PrivateFrameworks/TCC'; then
  print -u2 "The binary still calls TCC directly (a private API). Was it built with -D MAS_BUILD?"; exit 1
fi
signed=$(/usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)
for key in com.apple.security.app-sandbox com.apple.application-identifier com.apple.developer.team-identifier; do
  print -r -- "$signed" | grep -q "\"$key\"" || { print -u2 "Signed without $key"; exit 1; }
done
info="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")" == "$MAS_BUILD_NUMBER" ]] || { print -u2 "Build number mismatch"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$info")" == "false" ]] || { print -u2 "No encryption answer in Info.plist"; exit 1; }
lipo -archs "$binary" | grep -qx arm64 || { print -u2 "Expected an arm64-only binary (never upload x86_64 to this record)"; exit 1; }
# The website build updates itself with Sparkle; store apps may only update through the store (2.4.5(vii)).
if [[ -e "$app/Contents/Frameworks/Sparkle.framework" ]] || /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info" >/dev/null 2>&1 \
   || otool -L "$binary" | grep -qi sparkle || strings "$binary" | grep -qE 'SUUpdater|SPUStandardUpdater'; then
  print -u2 "Sparkle (the website build's updater) is in the store build. Keep it to --share and #if !MAS_BUILD."; exit 1
fi

# 4. The installer package the store takes.
pkg="$root/dist/mas/${MAS_NAME// /-}-$MAS_VERSION-$MAS_BUILD_NUMBER.pkg"
rm -f "$pkg"
/usr/bin/productbuild --component "$app" /Applications --sign "$MAS_INSTALLER_SIGN_IDENTITY" "$pkg"
/usr/sbin/pkgutil --check-signature "$pkg"
print -r -- "Package: $pkg"

(( validate )) || exit 0

# 5. App Store Connect. Credentials from mas.env: an API key, or the keychain item made by
#    xcrun altool --store-password-in-keychain-item "$MAS_UPLOAD_KEYCHAIN_ITEM" -u <Apple ID> -p <app-specific password>
auth=()
if [[ -n "$MAS_API_KEY_ID" && -n "$MAS_API_ISSUER_ID" ]]; then
  auth=(--apiKey "$MAS_API_KEY_ID" --apiIssuer "$MAS_API_ISSUER_ID")
elif /usr/bin/security find-generic-password -l "$MAS_UPLOAD_KEYCHAIN_ITEM" >/dev/null 2>&1; then
  auth=(-p "@keychain:$MAS_UPLOAD_KEYCHAIN_ITEM")
else
  print -u2 "No upload credentials: set MAS_API_KEY_ID and MAS_API_ISSUER_ID in Scripts/mas/mas.env, or save the"
  print -u2 "keychain item \"$MAS_UPLOAD_KEYCHAIN_ITEM\" (see the comment above). The package is ready at $pkg."
  exit 1
fi
xcrun altool --validate-app -f "$pkg" -t macos "${auth[@]}"
if (( upload )); then
  xcrun altool --upload-app -f "$pkg" -t macos "${auth[@]}"
  print -r -- "Uploaded $MAS_NAME $MAS_VERSION ($MAS_BUILD_NUMBER). It shows in App Store Connect › TestFlight after processing."
fi
