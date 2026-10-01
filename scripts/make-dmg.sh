#!/bin/sh
# Builds a Release copy and packages it as dist/Daptastic.dmg — the app plus an Applications
# shortcut, for the usual drag-to-install.
#
#   --quarantine  mark the image as downloaded from the internet, so Gatekeeper treats it the
#                 way it would for a real user (without Developer ID signing and notarisation,
#                 macOS will refuse to open it until "Open Anyway" is used).
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project Daptastic.xcodeproj -scheme Daptastic -configuration Release \
    -derivedDataPath .build/xcode -allowProvisioningUpdates build -quiet
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R .build/xcode/Build/Products/Release/Daptastic.app "$stage/"
ln -s /Applications "$stage/Applications"
mkdir -p dist
rm -f dist/Daptastic.dmg
hdiutil create -quiet -volname Daptastic -srcfolder "$stage" -fs HFS+ -format UDZO dist/Daptastic.dmg
if [ "${1:-}" = "--quarantine" ]; then
    xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" dist/Daptastic.dmg
fi
echo "dist/Daptastic.dmg"
