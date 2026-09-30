#!/bin/sh
# Builds daptastic. If Config/Signing.xcconfig names a certificate, signs with it so the
# Keychain sees a stable identity: one "Always Allow" lasts across rebuilds. (`swift run`
# re-signs ad-hoc, which makes every build a stranger to the Keychain.)
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product daptastic
bin="$(swift build -c release --show-bin-path)/daptastic"
identity="$(sed -n 's/^CODE_SIGN_IDENTITY *= *//p' Config/Signing.xcconfig 2>/dev/null || true)"
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
    codesign --force --sign "$identity" --identifier cc.jofam.daptastic.cli "$bin"
else
    echo "note: no Config/Signing.xcconfig; leaving the CLI ad-hoc signed" >&2
fi
echo "$bin"
