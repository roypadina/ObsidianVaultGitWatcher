#!/bin/sh
# Builds ObsidianVaultGitWatcher.app: swiftc the App/ sources into one binary, wire in
# the icons + Info.plist, ad-hoc sign. No Xcode project, no third-party deps.
#   ./build.sh        -> build/ObsidianVaultGitWatcher.app  (local dev/testing)
#   ./build.sh dist   -> also dist/ObsidianVaultGitWatcher.zip (release asset: stripped,
#                        no build paths in the binary)
set -e
cd "$(dirname "$0")"

APP_NAME=ObsidianVaultGitWatcher
APP=build/$APP_NAME.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# macOS 14 is the oldest the Settings window (SwiftUI) supports; matches Info.plist
# Universal: one swiftc per arch, merged with lipo.
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos14" -file-prefix-map "$PWD=." App/*.swift -o "build/$APP_NAME-$ARCH"
done
lipo -create "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
rm -f "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/icons/AppIcon.icns Assets/icons/menubar.png Assets/icons/menubar@2x.png "$APP/Contents/Resources/"

if [ "$1" = "dist" ]; then
  strip -S -x "$APP/Contents/MacOS/$APP_NAME"
fi
codesign --force --deep -s - "$APP" 2>/dev/null || true
echo "Built $APP"

if [ "$1" = "dist" ]; then
  mkdir -p dist
  rm -f "dist/$APP_NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$APP_NAME.zip"
  echo "Packaged dist/$APP_NAME.zip"
fi
