#!/bin/bash
# Builds a disk image (dist/Fenestra-<version>.dmg) to install Fenestra on another Mac without Xcode.
# Run on the Mac that has Xcode:  ./package.sh
#
# Signing, best available:
#   - "Developer ID Application" certificate in the keychain (Apple Developer Program): signed for distribution,
#     and notarized + stapled when a notarytool profile named "fenestra-notary" exists
#     (create it once: xcrun notarytool store-credentials fenestra-notary). The disk image then opens on any Mac
#     with no warning.
#   - Otherwise ad-hoc (no certificate, no identity in the signature): the other Mac shows a warning on first
#     open, which System Settings > Privacy & Security > Open Anyway clears (INSTALL.md explains it), and macOS
#     asks for the permissions again after each update. The "Apple Development" certificate is never used here:
#     it is for local builds and puts your Apple ID email in the signature.
set -euo pipefail
cd "$(dirname "$0")"

ENTITLEMENTS="Config/Fenestra-dist.entitlements"
NOTARY_PROFILE="fenestra-notary"

echo "Building (Release)..."
xcodebuild -project Fenestra.xcodeproj -target Fenestra -configuration Release SYMROOT="$PWD/build" build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[ -d build/Release/Fenestra.app ] || { echo "Build failed."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Release/Fenestra.app/Contents/Info.plist)"
STAGE="build/dmg-stage"
DMG="dist/Fenestra-$VERSION.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
ditto build/Release/Fenestra.app "$STAGE/Fenestra.app"

identity() { security find-identity -v -p codesigning | grep -F "\"$1" | head -1 | sed -E 's/.*"(.*)"/\1/' || true; }
DEVID="$(identity 'Developer ID Application')"
if [ -n "$DEVID" ]; then
  SIGN="$DEVID"; KIND="Developer ID"
  TIMESTAMP=(--timestamp)
else
  SIGN="-"; KIND="ad-hoc, not notarizable"
  TIMESTAMP=(--timestamp=none)
fi
echo "Signing: $KIND"
# Drop Xcode's local signature entirely (re-signing over it leaves its old bytes, Apple ID email included, in the
# signature padding), then strip debug symbols: the symbol table records build paths (your home folder). Crash
# symbolication uses the dSYM in build/Release, which stays local.
codesign --remove-signature "$STAGE/Fenestra.app"
strip -S -x "$STAGE/Fenestra.app/Contents/MacOS/Fenestra"
# Hardened runtime, release entitlements (no debugger attach, Apple events allowed).
codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements "$ENTITLEMENTS" --sign "$SIGN" "$STAGE/Fenestra.app"
codesign --verify --strict "$STAGE/Fenestra.app"

ln -s /Applications "$STAGE/Applications"
cp INSTALL.md "$STAGE/How to install Fenestra.txt"

echo "Creating $DMG"
rm -f "$DMG"
hdiutil create -quiet -volname "Fenestra $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ -ov "$DMG"

if [ -n "$DEVID" ]; then
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Notarizing (a few minutes)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    KIND="Developer ID, notarized"
  else
    echo "No notarytool profile \"$NOTARY_PROFILE\": signed but not notarized."
  fi
fi
rm -rf "$STAGE"
echo "Done: $DMG ($KIND, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
