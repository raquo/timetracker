#!/bin/bash
# End-to-end test: the real tracker (build/TimeTracker.app, which holds the Accessibility
# permission) records into a temporary database while the test drives two copies of the
# E2ETarget app, then a throwaway Google Chrome; then the rows are checked. See
# Tests/TrackerE2ETests.
#
# Takes over the screen for about 80 s: don't click or type meanwhile (moving the mouse is fine).
# Your own tracker and Chrome keep running; your tracker records the run too.
#
# KEEP=1 keeps the run folder (database, pages, Chrome's profile) for a look afterwards.
# CHROME=<path to the app> drives another Chrome; CHROME= (empty) skips Chrome's steps.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

TMP="${TMPDIR:-/tmp/}"
TMP="${TMP%/}"
LOCK="$TMP/timetracker-e2e.lock"
RUN_PREFIX="$TMP/timetracker-e2e-run."
E2E_APPS="build/e2e"
TRACKER_BIN="$PWD/$BUILD_APP/Contents/MacOS/TimeTracker"
CHROME="${CHROME-/Applications/Google Chrome.app}"
if [[ -n "$CHROME" && ! -d "$CHROME" ]]; then
    echo "error: no Chrome at $CHROME (CHROME= skips Chrome's steps)" >&2
    exit 1
fi

# The lock holds the pid of the run that took it, so a lock left by a killed run is taken over.
if ! mkdir "$LOCK" 2>/dev/null; then
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
        echo "error: another e2e run (pid $holder) is running" >&2
        exit 1
    fi
    echo "Taking over the lock of a run that died (pid ${holder:-unknown})"
fi
echo $$ > "$LOCK/pid"

# Leftovers of a run that died without cleaning up: its target apps and Chrome (their arguments
# name the run folder), a tracker running from the build copy (also stops a `--dump-ax` run from
# it), and run folders.
pkill -f "$RUN_PREFIX" || true
pkill -f "$TRACKER_BIN" || true
rm -rf "$RUN_PREFIX"*

RUN=""
cleanup() {
    if [[ -n "$RUN" ]]; then
        pkill -f "$RUN" || true
        if [[ "${KEEP:-}" == "1" ]]; then
            echo "Kept $RUN"
        else
            rm -rf "$RUN"
        fi
    fi
    pkill -f "$TRACKER_BIN" || true
    rm -rf "$LOCK"
}
trap cleanup EXIT

scripts/build.sh

swift build --product E2ETarget
TARGET_BIN="$(swift build --show-bin-path)/E2ETarget"
mkdir -p "$E2E_APPS"
for letter in A B; do
    app="$E2E_APPS/E2E Target $letter.app"
    id="com.raquo.timetracker.e2e-target-$(echo "$letter" | tr A-Z a-z)"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$TARGET_BIN" "$app/Contents/MacOS/E2ETarget"
    sed -e "s/__BUNDLE_ID__/$id/" -e "s/__NAME__/E2E Target $letter/" Resources/E2ETarget-Info.plist > "$app/Contents/Info.plist"
    codesign --force --sign - "$app"
done

# As made, not resolved (/var/… rather than /private/var/…): the test passes it to the target
# apps as given, and pkill matches their arguments as text.
RUN="$(mktemp -d "${RUN_PREFIX}XXXXXX")"

TIMETRACKER_E2E_TRACKER="$PWD/$BUILD_APP" \
TIMETRACKER_E2E_APPS="$PWD/$E2E_APPS" \
TIMETRACKER_E2E_RUN="$RUN" \
TIMETRACKER_E2E_CHROME="$CHROME" \
    swift test --filter TrackerE2ETests
