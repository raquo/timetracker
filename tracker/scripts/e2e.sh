#!/bin/bash
# End-to-end tests: the real tracker (build/TimeTracker.app, which holds the Accessibility
# permission) records into a temporary database while each test drives copies of the E2ETarget
# app, a throwaway Google Chrome or a throwaway Firefox; then the rows are checked. See
# docs/end-to-end-tests.md.
#
# `scripts/e2e.sh` runs every test in EndToEndTests; `scripts/e2e.sh chrome firefox` runs only
# those, by their function names there. An unknown name lists them.
#
# Needs a one-time Accessibility grant for build/e2e/E2E Helper.app (if it's missing, the script
# says how and stops).
#
# Takes over the screen for about 2.5 minutes, all tests together: don't click or type meanwhile
# (moving the mouse is fine). Your own tracker, Chrome and Firefox keep running; your tracker
# records the run too.
#
# KEEP=1 keeps the run folder (databases, pages, the browsers' profiles) for a look afterwards,
# until the next run.
# TIMETRACKER_E2E_CHROME=<path to the app> drives another Chrome; set but empty, the chrome test
# skips itself.
# TIMETRACKER_E2E_FIREFOX=<path to the app> likewise for Firefox. Not set: Firefox, else Firefox
# Developer Edition, from /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh
NAMES=("$@")

TMP="${TMPDIR:-/tmp/}"
TMP="${TMP%/}"
LOCK="$TMP/timetracker-e2e.lock"
RUN_PREFIX="$TMP/timetracker-e2e-run."
E2E_APPS="build/e2e"
TRACKER_BIN="$PWD/$BUILD_APP/Contents/MacOS/TimeTracker"
CHROME="${TIMETRACKER_E2E_CHROME-/Applications/Google Chrome.app}"
if [[ -n "$CHROME" && ! -d "$CHROME" ]]; then
    echo "error: no Chrome at $CHROME (TIMETRACKER_E2E_CHROME= skips the chrome test)" >&2
    exit 1
fi
if [[ -z "${TIMETRACKER_E2E_FIREFOX+set}" ]]; then
    FIREFOX="/Applications/Firefox.app"
    if [[ ! -d "$FIREFOX" ]]; then
        FIREFOX="/Applications/Firefox Developer Edition.app"
    fi
else
    FIREFOX="$TIMETRACKER_E2E_FIREFOX"
fi
if [[ -n "$FIREFOX" && ! -d "$FIREFOX" ]]; then
    if [[ -z "${TIMETRACKER_E2E_FIREFOX+set}" ]]; then
        echo "error: neither Firefox nor Firefox Developer Edition is in /Applications (TIMETRACKER_E2E_FIREFOX= skips the firefox test)" >&2
    else
        echo "error: no Firefox at $FIREFOX (TIMETRACKER_E2E_FIREFOX= skips the firefox test)" >&2
    fi
    exit 1
fi

# The lock holds the pid of the run that took it, so a lock left by a killed run is taken over.
# A lock with no pid yet is a run that's just starting. A pid that's alive but not an e2e.sh
# was reused by another process after the run died.
if ! mkdir "$LOCK" 2>/dev/null; then
    sleep 1
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -z "$holder" ]]; then
        echo "error: another e2e run is starting (or one left $LOCK without a pid: remove it)" >&2
        exit 1
    fi
    if kill -0 "$holder" 2>/dev/null && ps -o command= -p "$holder" | grep -q "e2e\.sh"; then
        echo "error: another e2e run (pid $holder) is running" >&2
        exit 1
    fi
    echo "Taking over the lock of a run that died (pid $holder)"
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"

# Leftovers of a run that died without cleaning up: its target apps and browsers (their arguments
# name the run folder), a tracker running from the build copy (also stops a `--dump-ax` or
# `--watch-ax` run from it), and run folders (a KEEP=1 one too).
pkill -f "$RUN_PREFIX" || true
pkill -f "$TRACKER_BIN" || true
rm -rf "$RUN_PREFIX"*

# A process and everything it started.
kill_tree() {
    local child
    for child in $(pgrep -P "$1"); do
        kill_tree "$child"
    done
    kill "$1" 2>/dev/null || true
}

RUN=""
TEST_PID=""
WATCHDOG_PID=""
cleanup() {
    if [[ -n "$TEST_PID" ]]; then
        kill_tree "$TEST_PID"
    fi
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
    if [[ -n "$WATCHDOG_PID" ]]; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# The helper first, so a missing Accessibility grant stops the run in seconds, before the slow
# builds. Signed with the tracker's identity, not ad hoc: the grant is tied to the signature, and
# an ad-hoc one changes on every build.
# No -v: that lists only trusted identities, and a self-signed certificate isn't one.
if ! security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
    echo "error: signing identity '$SIGN_IDENTITY' not found in keychain: E2E Helper needs it to keep its Accessibility grant (see tracker/README.md)." >&2
    exit 1
fi
swift build --product E2EHelper
mkdir -p "$E2E_APPS"
HELPER_APP="$PWD/$E2E_APPS/E2E Helper.app"
rm -rf "$HELPER_APP"
mkdir -p "$HELPER_APP/Contents/MacOS"
cp "$(swift build --show-bin-path)/E2EHelper" "$HELPER_APP/Contents/MacOS/E2EHelper"
cp Resources/E2EHelper-Info.plist "$HELPER_APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" "$HELPER_APP"
# Through `open`, so macOS asks about the helper's permission, not this terminal's.
ACCESS="$LOCK/helper-access"
open -n -W "$HELPER_APP" --args --check-access "$ACCESS"
if [[ "$(cat "$ACCESS" 2>/dev/null)" != "trusted" ]]; then
    echo "error: E2E Helper has no Accessibility permission. Once: System Settings → Privacy & Security → Accessibility → + → add $HELPER_APP and switch it on, then run again." >&2
    exit 1
fi

scripts/build.sh

# The tests to run, by name, from the test list itself: `chrome()` is `chrome`. Builds E2ETarget
# too.
swift build --build-tests
ALL_TESTS=($(swift test list --skip-build | sed -n 's|^TrackerE2ETests\.EndToEndTests/\(.*\)()$|\1|p'))
if [[ ${#ALL_TESTS[@]} -eq 0 ]]; then
    echo "error: found no tests in TrackerE2ETests.EndToEndTests" >&2
    exit 1
fi
if [[ ${#NAMES[@]} -eq 0 ]]; then
    TESTS=("${ALL_TESTS[@]}")
else
    TESTS=()
    for name in "${NAMES[@]}"; do
        if [[ " ${ALL_TESTS[*]} " != *" $name "* ]]; then
            echo "error: no test $name; there are: ${ALL_TESTS[*]}" >&2
            exit 1
        fi
        TESTS+=("$name")
    done
fi
FILTERS=()
for name in "${TESTS[@]}"; do
    FILTERS+=(--filter "^TrackerE2ETests\.EndToEndTests/$name\(\)")
done

TARGET_BIN="$(swift build --show-bin-path)/E2ETarget"
for letter in A B C; do
    app="$E2E_APPS/E2E Target $letter.app"
    id="com.raquo.timetracker.e2e-target-$(echo "$letter" | tr A-Z a-z)"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$TARGET_BIN" "$app/Contents/MacOS/E2ETarget"
    sed -e "s/__BUNDLE_ID__/$id/" -e "s/__NAME__/E2E Target $letter/" Resources/E2ETarget-Info.plist > "$app/Contents/Info.plist"
    # A page loaded from inside the app: its own UI, not content (docs/page-reading.md).
    echo "<!doctype html><title>Own UI</title><body><h1>Own UI</h1></body>" > "$app/Contents/Resources/own.html"
    codesign --force --sign - "$app"
done

# As made, not resolved (/var/… rather than /private/var/…): the test passes it to the target
# apps as given, and pkill matches their arguments as text.
RUN="$(mktemp -d "${RUN_PREFIX}XXXXXX")"

# If this script is killed outright (SIGKILL: no trap runs), this cleans up after it instead.
# Detached and immune to the terminal closing; `cleanup` stops it on any other exit. Given its
# values in the environment, not as arguments, so its own `pkill -f` doesn't match it.
E2E_PID=$$ E2E_RUN="$RUN" E2E_TRACKER_BIN="$TRACKER_BIN" E2E_LOCK="$LOCK" nohup bash -c '
    while kill -0 "$E2E_PID" 2>/dev/null; do
        sleep 1
    done
    pkill -f "$E2E_RUN" || true
    pkill -f "$E2E_TRACKER_BIN" || true
    rm -rf "$E2E_RUN"
    if [[ "$(cat "$E2E_LOCK/pid" 2>/dev/null)" == "$E2E_PID" ]]; then
        rm -rf "$E2E_LOCK"
    fi
' >/dev/null 2>&1 &
WATCHDOG_PID=$!

# In the background, so a signal to this script is handled at once (bash runs traps only
# between commands, so not during a foreground `swift test`).
TIMETRACKER_E2E_TRACKER="$PWD/$BUILD_APP" \
TIMETRACKER_E2E_APPS="$PWD/$E2E_APPS" \
TIMETRACKER_E2E_HELPER="$HELPER_APP" \
TIMETRACKER_E2E_RUN="$RUN" \
TIMETRACKER_E2E_CHROME="$CHROME" \
TIMETRACKER_E2E_FIREFOX="$FIREFOX" \
    swift test --skip-build "${FILTERS[@]}" &
TEST_PID=$!
wait "$TEST_PID"
TEST_PID=""

# `swift test` also passes when a test was skipped (an environment variable that didn't reach
# it, a filter that matched nothing), so each test leaves a note once it has checked its run.
for name in "${TESTS[@]}"; do
    CHECKED="$RUN/$name/checked"
    if [[ ! -f "$CHECKED" ]]; then
        echo "error: the test $name didn't check a run (skipped?): no $CHECKED" >&2
        exit 1
    fi
    echo "Checked $name: $(cat "$CHECKED")"
done
