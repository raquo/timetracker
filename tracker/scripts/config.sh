# Shared settings for the tracker scripts. Override any of these in the environment.

# Also the LaunchAgent label. Changing it means re-granting permissions.
BUNDLE_ID="${TIMETRACKER_BUNDLE_ID:-com.raquo.timetracker.tracker}"

# Name of a code signing identity in your keychain (see `security find-identity -p codesigning`).
# A self-signed one shows as CSSMERR_TP_NOT_TRUSTED; that's fine for signing and for permission grants.
# Permissions are tied to the signature: an ad-hoc signature changes on every build and silently loses them.
SIGN_IDENTITY="${TIMETRACKER_SIGN_IDENTITY:-Time Tracker}"

APP_NAME="TimeTracker.app"
BUILD_APP="build/$APP_NAME"
INSTALL_APP="$HOME/Applications/$APP_NAME"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
