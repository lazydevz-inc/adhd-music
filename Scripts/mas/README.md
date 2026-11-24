# Mac App Store build

Second channel next to the website dmg (`Scripts/package-share.sh`). Same songs, sounds, name and bundle id
(`app.adhdmusic.mac`); differences are compiled in with `-D MAS_BUILD`:

- no private TCC calls: the first Core Audio tap brings up macOS's "record your system audio" question;
- no developer launch options (`--data-dir`, `--scenario`, …) and no `--print-login-status`;
- 'Open at login' starts off and is never turned on at launch; the Settings switch registers it;
- App Sandbox (`entitlements.plist`), privacy manifest (`PrivacyInfo.xcprivacy`), Xcode's DT* keys and
  `ITSAppUsesNonExemptEncryption = false` in Info.plist.

Commands:

```bash
Scripts/build-app.sh --mas                      # dist/mas/ADHD Music.app, Apple Development signed (look only; don't run it here, see below)
Scripts/build-app.sh --mas --keep-dev-options   # build/mas-test/…, id app.adhdmusic.mac.test, for sandbox tests with --data-dir etc.
Scripts/package-mas.sh                          # store-signed dist/mas/ADHD-Music-<version>-<build>.pkg, checked, nothing uploaded
Scripts/package-mas.sh --validate               # + App Store Connect validation
Scripts/package-mas.sh --upload                 # + upload (an upload uses up its build number)
```

Don't open `dist/mas/ADHD Music.app` on a Mac that also runs the website build: it has the same id, and macOS
would ask for the sound permission again for the new signature, which can drop the website copy's permission.
Test the store code with `--keep-dev-options` (its own id) instead.

## Status

The store build is not released yet; the website build comes first. Both are free. 'Open at login': the website
build turns it on at first launch; the store build starts with it off.

Both channels side by side (website from 1.0.1 on):
1. Same data: the website build is sandboxed too (Scripts/share/entitlements-sandbox.plist), so both use
   ~/Library/Containers/app.adhdmusic.mac. A container-migration.plist in both builds moves what 1.0 build 2 kept in
   ~/Library/Application Support/ADHD Music and ~/Library/Preferences/app.adhdmusic.mac.plist on first launch.
2. Same sound permission: the website build is signed with the requirement Xcode writes (TN3127): Mac App Store
   signature or this team's Developer ID. Apple re-signs store apps with a requirement of the same form, so either copy
   meets the other's. Grants made by 1.0 build 2 keep that build's narrower requirement: those people are asked once
   more if they switch to the store copy. package-mas.sh keeps Apple's default (a submission can't meet the
   store-only branch itself).
3. One copy at a time: a second launch quits at once (FocusMusicMain.anotherCopyIsRunning).
4. Sparkle stays in the website build only; package-mas.sh refuses a build that has it.
5. Opening the shared container with a copy signed another way (for example a development build) makes macOS ask
   once ("differs from previously opened versions"); a store copy may do the same the first time.

## Sandbox test (macOS 26.2)

- The tap hears another app inside the sandbox (quiet −40 dBFS tone in IINA: 0.93–1.01 s audible a second),
  pauses after 2 s, resumes 3 s after it stops; a silent file with its output open does not pause.
- Without TCC, the first tap shows "“…” would like access to record your system audio" with our purpose
  string. While it is unanswered the tap waits (about 90 s, then gives up and delivers nothing). Taps now start
  on their own queue, so checks go on and running output counts as sound meanwhile, as in the website build.
- App list, bundle ids and microphone-in-use flags read the same as outside the sandbox. Global hot key fires.
  Distributed notifications arrive. Now Playing registers. Login item registers and unregisters.
- Camera-in-use: CoreMediaIO lists 0 cameras in the sandbox (3 outside) unless
  `com.apple.security.device.camera` is added. Left out: calls are noticed by the microphone.
- Not tried: a real screen lock, a real call, pressing the keyboard play key (another app was playing).

## One-time account setup

Use your own team, names and app id (fill them in `mas.env`).

1. developer.apple.com › Certificates, IDs & Profiles › Identifiers › + › App IDs › App:
   a description, an explicit Bundle ID (`MAS_BUNDLE_ID`), no extra capabilities.
2. Certificates: an **Apple Distribution** certificate and a **Mac Installer Distribution** certificate
   (easiest in Xcode › Settings › Apple Accounts › Manage Certificates › +, which keeps the private keys in
   this Mac's login keychain). They show up as "Apple Distribution: YOUR NAME (YOUR_TEAM_ID)" and
   "3rd Party Mac Developer Installer: YOUR NAME (YOUR_TEAM_ID)".
3. Profiles › + › Distribution › **Mac App Store Connect** › your App ID › the Apple Distribution
   certificate › download to the path in `MAS_PROFILE` (never commit it).
4. appstoreconnect.apple.com › Apps › + › New App: macOS, your app's name, primary language, your bundle ID
   and a SKU. This reserves the name.
5. Upload credentials, one of: an App Store Connect API key (Users and Access › Integrations › Team Keys,
   role App Manager; `AuthKey_<id>.p8` into `~/.appstoreconnect/private_keys`, never into the repository; ids
   into `mas.env`), or an app-specific password saved with
   `xcrun altool --store-password-in-keychain-item "ADHD Music App Store" -u <Apple ID> -p <password>`.

Before submitting (App Store Connect): price, category Music (or Productivity; not Health & Fitness or
Medical), age rating 4+, App Privacy "Data Not Collected", a privacy policy URL (and a link inside the app per
guideline 5.1.1(i)), Content Rights (third-party content: the songs and sounds you ship), EU DSA trader status,
screenshots, and review notes that explain the menu bar and the system-audio question ("measures loudness only,
records and sends nothing").
