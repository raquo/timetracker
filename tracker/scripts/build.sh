#!/bin/bash
# Builds and signs build/TimeTracker.app.
# ALLOW_ADHOC=1 signs ad-hoc when the identity is missing (fine for smoke tests, loses permissions on every build).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TimeTracker"

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS"
cp "$BIN" "$BUILD_APP/Contents/MacOS/TimeTracker"
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" Resources/Info.plist > "$BUILD_APP/Contents/Info.plist"

# No -v: that lists only trusted identities, and a self-signed certificate isn't one.
if security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
    codesign --force --options runtime \
        --entitlements Resources/TimeTracker.entitlements \
        --sign "$SIGN_IDENTITY" "$BUILD_APP"
elif [[ "${ALLOW_ADHOC:-}" == "1" ]]; then
    echo "warning: signing identity '$SIGN_IDENTITY' not found, signing ad-hoc" >&2
    codesign --force --options runtime \
        --entitlements Resources/TimeTracker.entitlements \
        --sign - "$BUILD_APP"
else
    echo "error: signing identity '$SIGN_IDENTITY' not found in keychain." >&2
    echo "Create one (see tracker/README.md), set TIMETRACKER_SIGN_IDENTITY, or pass ALLOW_ADHOC=1." >&2
    exit 1
fi

codesign --verify --strict "$BUILD_APP"
echo "Built $BUILD_APP ($BUNDLE_ID)"
