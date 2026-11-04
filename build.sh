#!/bin/sh
# Builds ObsidianVaultGitWatcher.app: swiftc the App/ sources into one binary, wire in
# the icons + Info.plist, ad-hoc sign. No Xcode project. One third-party dep: Sparkle (in-app
# updates), the official release tarball, pinned by SHA-256 and cached in build/.
#   ./build.sh        -> build/ObsidianVaultGitWatcher.app  (local dev/testing)
#   ./build.sh dist   -> also dist/ObsidianVaultGitWatcher.zip (release asset: stripped,
#                        no build paths in the binary)
set -e
cd "$(dirname "$0")"

APP_NAME=ObsidianVaultGitWatcher
APP=build/$APP_NAME.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Sparkle: download once, verify, unpack into build/sparkle-<version>/ (Sparkle.framework + bin/).
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SPARKLE=build/sparkle-$SPARKLE_VERSION
if [ ! -d "$SPARKLE/Sparkle.framework" ]; then
  mkdir -p "$SPARKLE"
  curl -sfL -o "$SPARKLE.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $SPARKLE.tar.xz" | shasum -a 256 -c - >/dev/null
  tar -xJf "$SPARKLE.tar.xz" -C "$SPARKLE" ./Sparkle.framework ./bin
  rm -f "$SPARKLE.tar.xz"
fi

# macOS 14 is the oldest the Settings window (SwiftUI) supports; matches Info.plist
# Universal: one swiftc per arch, merged with lipo.
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos14" -file-prefix-map "$PWD=." -F "$SPARKLE" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks App/*.swift -o "build/$APP_NAME-$ARCH"
done
lipo -create "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
rm -f "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/icons/AppIcon.icns Assets/icons/menubar.png Assets/icons/menubar@2x.png "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"  # ditto keeps its symlinks

if [ "$1" = "dist" ]; then
  strip -S -x "$APP/Contents/MacOS/$APP_NAME"
fi
# Stable identity (when in the keychain) keeps macOS permission grants across updates; ad-hoc otherwise.
ID="${OBSIDIANVAULTGITWATCHER_SIGN_IDENTITY:-}"
if [ -z "$ID" ] && security find-identity -v -p codesigning | grep -q "KeyLayoutSwitcher Dev"; then
  ID="KeyLayoutSwitcher Dev"
fi
# Inside-out: Sparkle's helpers and framework, then the app. disable-library-validation: the
# self-signed hardened-runtime app has no Team ID, so library validation would refuse Sparkle.
SIGN="${ID:--}"
find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \
  -o \( -name Autoupdate -type f \) \) | while read -r f; do
  codesign --force --preserve-metadata=identifier,entitlements,flags -s "$SIGN" "$f"
done
if [ -n "$ID" ]; then
  codesign --force --options runtime --entitlements App.entitlements -s "$ID" "$APP"
  echo "Signed with: $ID"
else
  codesign --force -s - "$APP"
  echo "Stable signing identity not found: ad-hoc signed"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [ "$1" = "dist" ]; then
  mkdir -p dist
  rm -f "dist/$APP_NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$APP_NAME.zip"
  echo "Packaged dist/$APP_NAME.zip"
  # Sparkle feed for this release only (uploaded next to the zip; the app reads the latest release's
  # appcast.xml). Only with the key whose public half the app ships; any other key makes a feed every
  # copy refuses.
  if [ "$("$SPARKLE/bin/generate_keys" -p 2>/dev/null || true)" = "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' Info.plist)" ]; then
    VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
    D=$(mktemp -d)
    cp "dist/$APP_NAME.zip" "$D/"
    # This version's CHANGELOG section becomes the update prompt's release notes.
    awk -v v="## [$VER]" 'index($0, v) == 1 {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md > "$D/$APP_NAME.md"
    rm -f dist/appcast.xml  # generate_appcast merges into an existing file
    "$SPARKLE/bin/generate_appcast" --embed-release-notes \
      --download-url-prefix "https://github.com/roypadina/ObsidianVaultGitWatcher/releases/download/v$VER/" \
      -o dist/appcast.xml "$D"
    rm -rf "$D"
    echo "Feed dist/appcast.xml"
  else
    echo "Sparkle signing key (matching SUPublicEDKey) not in the keychain: no appcast.xml"
  fi
fi
