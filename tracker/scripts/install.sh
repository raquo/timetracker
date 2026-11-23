#!/bin/bash
# Builds the tracker, copies it to ~/Applications, and (re)starts it as a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/config.sh

scripts/build.sh

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$BUNDLE_ID" 2>/dev/null || true

# A fixed install path, so permission grants survive rebuilds (they key on path + signature).
mkdir -p "$(dirname "$INSTALL_APP")" "$(dirname "$LAUNCH_AGENT")"
rm -rf "$INSTALL_APP"
ditto "$BUILD_APP" "$INSTALL_APP"

cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_APP/Contents/MacOS/TimeTracker</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT"
echo "Installed $INSTALL_APP and started LaunchAgent $BUNDLE_ID"
echo "Logs: /usr/bin/log stream --info --predicate 'subsystem == \"timetracker.tracker\"'"
