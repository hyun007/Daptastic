#!/bin/sh
# Builds the app (Release) and installs it to /Applications, replacing any older copy.
# The login item points at whichever copy registered it, so run the installed one.
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project Daptastic.xcodeproj -scheme Daptastic -configuration Release \
    -derivedDataPath .build/xcode build -quiet
osascript -e 'tell application "Daptastic" to quit' 2>/dev/null || true
rm -rf /Applications/Daptastic.app
cp -R .build/xcode/Build/Products/Release/Daptastic.app /Applications/
open /Applications/Daptastic.app
echo "installed /Applications/Daptastic.app"
