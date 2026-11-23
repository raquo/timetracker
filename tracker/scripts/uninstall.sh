#!/bin/bash
# Stops the LaunchAgent and removes the installed app. Keeps the database.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -f "$LAUNCH_AGENT"
rm -rf "$INSTALL_APP"
echo "Uninstalled $BUNDLE_ID. Database left in ~/Library/Application Support/com.raquo.timetracker/"
