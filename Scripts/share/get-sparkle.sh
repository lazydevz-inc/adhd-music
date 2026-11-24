#!/bin/zsh
# Puts Sparkle (the website build's updater) in build/vendor/Sparkle-<version>: the official release archive
# from github.com/sparkle-project/Sparkle, checked against the SHA-256 in share.env. Does nothing when it is
# already there. build/ is never part of the public repository; Sparkle is MIT-licensed (its LICENSE ships
# inside the framework).
set -euo pipefail

root="${0:A:h:h:h}"
source "$root/Scripts/share/share.env"
dest="$root/build/vendor/Sparkle-$SPARKLE_VERSION"
if [[ -d "$dest/Sparkle.framework" && -x "$dest/bin/generate_appcast" ]]; then
  print -r -- "$dest"
  exit 0
fi

archive="$root/build/vendor/download/Sparkle-$SPARKLE_VERSION.tar.xz"
mkdir -p "${archive:h}"
if [[ ! -f "$archive" ]]; then
  curl -fsSL -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
fi
sum=$(shasum -a 256 "$archive" | awk '{ print $1 }')
if [[ "$sum" != "$SPARKLE_SHA256" ]]; then
  print -u2 "Sparkle-$SPARKLE_VERSION.tar.xz does not match the SHA-256 in share.env ($sum); removed it."
  rm -f "$archive"
  exit 1
fi
rm -rf "$dest"
mkdir -p "$dest"
tar -xJf "$archive" -C "$dest"
print -r -- "$dest"
