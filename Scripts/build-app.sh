#!/bin/zsh
# Builds ADHD Music.app.
#   Scripts/build-app.sh            → dist/ADHD Music.app (app.adhdmusic.local): your own build, with its own id
#                                     and data folder (Application Support/Focus Music), apart from the downloaded app
#   Scripts/build-app.sh --dev      → build/Focus Music Dev.app (app.adhdmusic.local.dev, data in
#                                     Application Support/Focus Music Dev)
#   Scripts/build-app.sh --share    → dist/share/<name>.app: the free build for other Macs (name and id in
#                                     Scripts/share/share.env; Scripts/package-share.sh notarizes it into a dmg).
#                                     The only build with Sparkle (silent daily updates, -D SPARKLE, Updates.swift).
#                                     From 1.0.1 (SHARE_SANDBOX=1) sandboxed like --mas: same data folder in
#                                     ~/Library/Containers/<id>, earlier data moved in on first launch
#                                     (container-migration.plist), a signing rule both builds meet (shared permission).
#   Scripts/build-app.sh --mas      → dist/mas/<name>.app: the Mac App Store build (Scripts/mas/mas.env). Same
#                                     songs and sounds as --share, compiled with -D MAS_BUILD: no private TCC
#                                     calls, no developer launch options, 'Open at login' off until turned on,
#                                     App Sandbox (Scripts/mas/entitlements.plist). Signed here with Apple
#                                     Development for a local look; Scripts/package-mas.sh signs it for the store.
#   --mas --keep-dev-options        → build/mas-test/<name>.app, id <id>.test: the store code with the developer
#                                     options left in, for sandbox tests on this Mac (never upload it)
#   add --stub to compile against Tests/Stubs/AudioEngineStub.swift instead of Sources/Audio
#   --allow-missing-noise: build without the rain/waves/stream loops; those three stay silent (never hand out
#                          a --share or --mas build made this way)
set -euo pipefail

root="${0:A:h:h}"
mode="release"
use_stub=0
allow_missing_noise=0
keep_dev_options=0
for arg in "$@"; do
  case "$arg" in
    --dev) mode="dev" ;;
    --share) mode="share" ;;
    --mas) mode="mas" ;;
    --keep-dev-options) keep_dev_options=1 ;;
    --stub) use_stub=1 ;;
    --allow-missing-noise) allow_missing_noise=1 ;;
  esac
done

# The icon step needs actool, which comes with Xcode, not with the Command Line Tools alone.
if ! xcrun --find actool >/dev/null 2>&1; then
  print -u2 "actool not found. Make Xcode the active developer directory:"
  print -u2 "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

local_id="app.adhdmusic.local"; dev_id="app.adhdmusic.local.dev"
share_id=$( { source "$root/Scripts/share/share.env" && print -r -- "$SHARE_BUNDLE_ID"; } 2>/dev/null || true)

if [[ "$mode" == "dev" ]]; then
  name="Focus Music Dev"; bundle_id="$dev_id"; out_dir="$root/build"
  version="1.0.0"; build_number="2"
elif [[ "$mode" == "share" ]]; then
  source "$root/Scripts/share/share.env"
  # share.env ships with placeholders for the signing identity: stop before building an app nobody can sign.
  if [[ "$SHARE_SIGN_IDENTITY" == *"YOUR NAME"* || "$SHARE_SIGN_IDENTITY" == *"YOUR_TEAM_ID"* ]]; then
    print -u2 "Scripts/share/share.env still has the placeholder signing identity."
    print -u2 "Put your own Developer ID identity there first (and, for a build you share, your own name, app id,"
    print -u2 "feed and Sparkle key: see README.md, 'Make the .dmg')."
    exit 1
  fi
  name="$SHARE_NAME"; bundle_id="$SHARE_BUNDLE_ID"; out_dir="${SHARE_OUT_DIR:-$root/dist/share}"
  version="$SHARE_VERSION"; build_number="$SHARE_BUILD"
  sparkle="$root/build/vendor/Sparkle-$SPARKLE_VERSION"
  [[ -d "$sparkle/Sparkle.framework" ]] || { print -u2 "Sparkle $SPARKLE_VERSION is not in $sparkle: run Scripts/share/get-sparkle.sh"; exit 1; }
elif [[ "$mode" == "mas" ]]; then
  source "$root/Scripts/mas/mas.env"
  name="$MAS_NAME"; bundle_id="$MAS_BUNDLE_ID"; out_dir="$root/dist/mas"
  version="$MAS_VERSION"; build_number="$MAS_BUILD_NUMBER"
  if (( keep_dev_options )); then bundle_id="$MAS_BUNDLE_ID.test"; out_dir="$root/build/mas-test"; fi
else
  # A build of your own: its own id and its own data folder (Application Support/Focus Music),
  # apart from the downloaded app.
  name="ADHD Music"; bundle_id="$local_id"; out_dir="$root/dist"
  version="1.0.0"; build_number="3"
fi

# Every build knows the ids of the others (local, dev, shared), so one never pauses for another's music
# (Sources/App/Services.swift, OtherSoundMonitor.appName(for:)).
sibling_ids=""
for id in "$local_id" "$dev_id" "$share_id"; do
  if [[ -n "$id" ]]; then sibling_ids+="<string>$id</string>"; fi
done

app="$out_dir/$name.app"
[[ "$mode" == "share" || "$mode" == "mas" ]] && rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

audio_sources=("$root"/Sources/Audio/*.swift(N))
if (( use_stub )) || (( ${#audio_sources} == 0 )); then
  audio_sources=("$root/Tests/Stubs/AudioEngineStub.swift")
fi

swift_flags=()
if [[ "$mode" == "share" ]]; then
  # Sparkle is linked from Contents/Frameworks (copied and signed below).
  swift_flags+=(-D SPARKLE -F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
if [[ "$mode" == "mas" ]]; then
  swift_flags+=(-D MAS_BUILD)
  (( keep_dev_options )) && swift_flags+=(-D MAS_TEST)
fi

xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx26.0 "${swift_flags[@]}" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework Accelerate \
  -framework MediaPlayer -framework ServiceManagement \
  -framework CoreAudio -framework CoreMediaIO -framework Carbon \
  "$root"/Sources/App/*.swift "${audio_sources[@]}" \
  -o "$app/Contents/MacOS/FocusMusic"

# Rain, Waves and Stream: seamless FLAC loops in Audio/Noise/LoopsShare (not in the repository; the released
# app uses three CC0 field recordings from Freesound, credited in README.md).
noise_dir="$root/Audio/Noise/LoopsShare"
if [[ "$mode" == "share" ]]; then
  # Sparkle: check the feed once a day without asking first, download and install without asking, check the
  # EdDSA signature before unpacking, and accept only a feed signed with the same key. Updates.swift decides
  # when the installed update opens (a quiet moment, or the next quit).
  extra_keys="  <key>FocusDataFolder</key><string>${SHARE_DATA_FOLDER:-$name}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>SUFeedURL</key><string>$SHARE_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SHARE_SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
  <key>SUEnableSystemProfiling</key><false/>"
  # Sandboxed: Sparkle installs through its launcher service (network access comes from the entitlement).
  [[ "${SHARE_SANDBOX:-1}" == "1" ]] && extra_keys+="
  <key>SUEnableInstallerLauncherService</key><true/>"
elif [[ "$mode" == "mas" ]]; then
  # The keys Xcode writes into every app it builds; App Store Connect reads them to know the tools
  # behind a build. No encryption beyond what macOS provides, so no export question on each upload.
  xcode_version=$(xcodebuild -version | awk 'NR==1 { print $2 }')
  xcode_build=$(xcodebuild -version | awk 'NR==2 { print $3 }')
  dt_xcode=$(print -r -- "$xcode_version" | awk -F. '{ printf "%d%d%d", $1, $2, $3 }')
  sdk_version=$(xcrun --sdk macosx --show-sdk-version)
  sdk_build=$(xcrun --sdk macosx --show-sdk-build-version)
  extra_keys="  <key>FocusDataFolder</key><string>$name</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>BuildMachineOSBuild</key><string>$(sw_vers -buildVersion)</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key><string>$sdk_build</string>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTPlatformVersion</key><string>$sdk_version</string>
  <key>DTSDKBuild</key><string>$sdk_build</string>
  <key>DTSDKName</key><string>macosx$sdk_version</string>
  <key>DTXcode</key><string>$dt_xcode</string>
  <key>DTXcodeBuild</key><string>$xcode_build</string>"
elif [[ "$mode" == "release" ]]; then
  extra_keys="  <key>FocusDataFolder</key><string>Focus Music</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>"
else
  # The dev build keeps its records, likes, learning and library apart from your own build.
  extra_keys="  <key>FocusDataFolder</key><string>Focus Music Dev</string>"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FocusMusic</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAudioCaptureUsageDescription</key><string>$name pauses while another app, like a YouTube video, is playing sound and plays again when it stops. Nothing is recorded.</string>
  <key>FocusSiblingIDs</key><array>$sibling_ids</array>
$extra_keys
</dict></plist>
PLIST

# Background-noise recordings, read from Resources/Noise.
noise_out="$app/Contents/Resources/Noise"
rm -rf "$noise_out"
noise_files=("$noise_dir"/{rain,ocean,stream}.flac(N))
if (( ${#noise_files} < 3 )) && (( ! allow_missing_noise )); then
  print -u2 "Missing the noise loops in $noise_dir (rain.flac, ocean.flac, stream.flac). Add them, or build with --allow-missing-noise."
  exit 1
fi
if (( ${#noise_files} > 0 )); then
  mkdir -p "$noise_out"
  cp "${noise_files[@]}" "$noise_out/"
fi

# App icon: the menu bar headset as a macOS 26 glass icon (Scripts/share/AppIcon.icon, made for Icon Composer).
# actool writes Assets.car (the layered icon) and AppIcon.icns, plus the two Info.plist keys.
icon_plist=$(mktemp "${TMPDIR:-/tmp}/focus-icon.XXXXXX")
xcrun actool "$root/Scripts/share/AppIcon.icon" --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
  --standalone-icon-behavior all --output-partial-info-plist "$icon_plist" \
  --output-format human-readable-text --errors --warnings >/dev/null
/usr/libexec/PlistBuddy -c "Merge $icon_plist" "$app/Contents/Info.plist" >/dev/null
rm -f "$icon_plist"
[[ -f "$app/Contents/Resources/Assets.car" && -f "$app/Contents/Resources/AppIcon.icns" ]] || { print -u2 "App icon did not compile"; exit 1; }
# The permission question in Korean on Korean Macs.
mkdir -p "$app/Contents/Resources/ko.lproj" "$app/Contents/Resources/en.lproj"
cat > "$app/Contents/Resources/ko.lproj/InfoPlist.strings" <<STRINGS
"NSAudioCaptureUsageDescription" = "$name은 유튜브 영상처럼 다른 앱에서 소리가 나는 동안 멈추고, 소리가 그치면 다시 틀어요. 아무것도 녹음하지 않아요.";
STRINGS

# Sandboxed builds: on first launch macOS copies the data an earlier unsandboxed website build (1.0 build 2) kept
# in ~/Library/Application Support/<data folder>, and its settings, into the container both builds share.
# Apple: "Migrating your app's files to its App Sandbox container". Nothing happens when there is nothing to copy.
if [[ "$mode" == "mas" || ( "$mode" == "share" && "${SHARE_SANDBOX:-1}" == "1" ) ]]; then
  data_folder=$(/usr/libexec/PlistBuddy -c 'Print :FocusDataFolder' "$app/Contents/Info.plist")
  cat > "$app/Contents/Resources/container-migration.plist" <<MIGRATION
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Move</key>
  <array>
    <string>\${ApplicationSupport}/$data_folder</string>
    <string>\${Library}/Preferences/\${BundleId}.plist</string>
  </array>
</dict></plist>
MIGRATION
  plutil -lint -s "$app/Contents/Resources/container-migration.plist"
fi

# A designated requirement the Developer ID copy and the Mac App Store copy both meet (Apple TN3127, the form
# Xcode writes): macOS then lets either copy use the sound permission the other one got.
write_requirement() { # bundle id, team id, file
  print -r -- "designated => identifier \"$1\" and anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"$2\")" > "$3"
}

if [[ "$mode" == "mas" ]]; then
  # Same songs as the website build, from their own cache so the two builds never share a folder mid-build.
  cache="$root/build/mas-library"
  "$root/.venv-audio/bin/python" "$root/Scripts/share/bundle_library.py" \
    --library "$HOME/Library/Application Support/Focus Music/Library" --out "$cache"
  ditto "$cache" "$app/Contents/Resources/Library"
  cp "$root/Scripts/mas/PrivacyInfo.xcprivacy" "$app/Contents/Resources/PrivacyInfo.xcprivacy"

  # Sandboxed, signed with Apple Development so it can be opened here; package-mas.sh re-signs it with
  # Apple Distribution, the provisioning profile and the application identifier.
  identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')
  /usr/bin/codesign --force --options runtime --entitlements "$root/Scripts/mas/entitlements.plist" \
    --sign "${identity:--}" "$app"
  /usr/bin/codesign --verify --strict --verbose=1 "$app"
  print -r -- "$app"
  exit 0
fi

if [[ "$mode" == "share" ]]; then
  # The songs ship inside the app; the app uses them when the person has no library of their own.
  cache="$root/build/share-library"
  "$root/.venv-audio/bin/python" "$root/Scripts/share/bundle_library.py" \
    --library "$HOME/Library/Application Support/Focus Music/Library" --out "$cache"
  ditto "$cache" "$app/Contents/Resources/Library"

  # Sparkle.framework in Contents/Frameworks without its headers, signed from the inside out (XPC services,
  # Autoupdate, Updater.app, then the framework) with the same Developer ID, hardened runtime and timestamp.
  frameworks="$app/Contents/Frameworks"
  mkdir -p "$frameworks"
  ditto "$sparkle/Sparkle.framework" "$frameworks/Sparkle.framework"
  fw="$frameworks/Sparkle.framework"
  rm -rf "$fw"/{Headers,PrivateHeaders,Modules} "$fw"/Versions/B/{Headers,PrivateHeaders,Modules}
  sign=(/usr/bin/codesign --force --options runtime --timestamp --sign "$SHARE_SIGN_IDENTITY")
  "${sign[@]}" "$fw/Versions/B/XPCServices/Installer.xpc"
  "${sign[@]}" --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
  "${sign[@]}" "$fw/Versions/B/Autoupdate"
  "${sign[@]}" "$fw/Versions/B/Updater.app"
  "${sign[@]}" "$fw"

  # Developer ID + hardened runtime + secure timestamp: what notarization needs. Sandboxed from 1.0.1, with the
  # bundle id in Sparkle's mach-lookup names and the requirement the App Store copy also meets.
  # SHARE_SANDBOX=0 signs like 1.0 build 2 (no sandbox, codesign's default requirement), for update tests.
  if [[ "${SHARE_SANDBOX:-1}" == "1" ]]; then
    sign_dir=$(mktemp -d "${TMPDIR:-/tmp}/focus-share-sign.XXXXXX")
    sed "s/__BUNDLE_ID__/$bundle_id/g" "$root/Scripts/share/entitlements-sandbox.plist" > "$sign_dir/entitlements.plist"
    team=${${SHARE_SIGN_IDENTITY##*\(}%\)}
    write_requirement "$bundle_id" "$team" "$sign_dir/requirement.txt"
    /usr/bin/codesign --force --options runtime --timestamp \
      --entitlements "$sign_dir/entitlements.plist" -r "$sign_dir/requirement.txt" \
      --sign "$SHARE_SIGN_IDENTITY" "$app"
    rm -rf "$sign_dir"
  else
    /usr/bin/codesign --force --options runtime --timestamp \
      --entitlements "$root/Scripts/share/entitlements.plist" \
      --sign "$SHARE_SIGN_IDENTITY" "$app"
  fi
  /usr/bin/codesign --verify --strict --verbose=1 "$app"
  print -r -- "$app"
  exit 0
fi

# Sign with the developer certificate when there is one: macOS keeps the permission to hear other
# apps' sound only while the signature stays the same, and an ad-hoc one changes with every build.
identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $2; exit }')
/usr/bin/codesign --force --sign "${identity:--}" "$app"
/usr/bin/codesign --verify "$app"
print -r -- "$app"
