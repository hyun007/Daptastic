#!/bin/sh
# Puts this Mac back to "Daptastic was never installed", for testing first-run setup.
# Turn off "Open at login" in the app first: a login item can only be removed by the app.
#
# Left alone: the card (test with a spare card or a disk image), Navidrome (delete the
# "daptastic [Daptastic]" player there to re-test switching Report Real Path on), and macOS's
# Local Network permission, which can't be reset from the command line.
set -u
osascript -e 'tell application id "cc.jofam.daptastic" to quit' 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f Daptastic.app/Contents/MacOS/Daptastic >/dev/null || break
    sleep 1
done
rm -rf /Applications/Daptastic.app && echo "removed /Applications/Daptastic.app"
defaults delete cc.jofam.daptastic 2>/dev/null && echo "removed settings"
while security delete-generic-password -s cc.jofam.daptastic.navidrome >/dev/null 2>&1; do
    echo "removed saved password"
done
echo "done — Daptastic is uninstalled"
