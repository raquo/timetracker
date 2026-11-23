# Time Tracker: activity tracker

Swift menu-bar-less agent that records raw activity into `~/Library/Application Support/com.raquo.timetracker/timetracker.db`. See `../notes/PLAN.md`, `../notes/tracking-techniques.md` and `../notes/electron-and-claude.md`.

Records now: frontmost app, window title and kind (role, subrole, main, full screen), document path (`AXDocument`), page URL and title in browsers (Firefox, Safari, Chromium family) and allowlisted apps (Claude), idle (≥ 60 s without input, backdated to the last input), screen lock, sleep gaps. URLs are scrubbed before writing (no fragment, credentials or secret-looking query parameters; see `URLScrubber.swift`). A changed sample is recorded only once a second sample ~400 ms later agrees (`Settler.swift`). Not yet: power assertions, camera/mic, menu bar item. Samples on Accessibility events, on clicks, and on a 5 s poll; see `../notes/tracking-techniques.md`.

## One-time setup: signing identity

Permissions are tied to the code signature, so the app must be signed with the same identity every build.

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name `Time Tracker`, Identity Type "Self Signed Root", Certificate Type "Code Signing". Create.
3. Check: `security find-identity -p codesigning` lists `"Time Tracker"` (marked CSSMERR_TP_NOT_TRUSTED, which is fine).

A different name works too: set `TIMETRACKER_SIGN_IDENTITY`.

## Build, install, run

```bash
scripts/install.sh    # build, sign, copy to ~/Applications, start LaunchAgent
scripts/uninstall.sh  # stop and remove (keeps the database)
```

Then grant Accessibility to "Time Tracker" in System Settings → Privacy & Security → Accessibility.

Logs: `/usr/bin/log stream --predicate 'subsystem == "timetracker.tracker"' --info` (`/usr/bin/log`, since zsh has a `log` builtin that shadows it; `--info` to include info messages). Past logs: `/usr/bin/log show --last 1h --info --predicate …`

For a quick test without installing: `ALLOW_ADHOC=1 scripts/build.sh`, copy `build/TimeTracker.app/Contents/MacOS/TimeTracker` out of the bundle, and run it with `TIMETRACKER_DB=/some/test.db`. Run from a terminal it gets the terminal's permissions, not its own, so titles stay empty; and run inside the bundle it would show the Accessibility prompt. Only one tracker can record to a given database (lock file `<db>.lock`); a second one exits.

## Page URL and title from app web content

For browsers and allowlisted apps the tracker records the URL and title of the page in the focused window (`url_id`, `page_title_id`), read from the app's web Accessibility tree. Built in: the browsers in `Apps/Browsers.swift` (they expose the shown tab without a switch) and Claude (`com.anthropic.claudefordesktop`, an Electron app whose tree the tracker switches on). Further Electron apps can be added; this costs each app some CPU and memory, so keep the list short.

```bash
defaults write com.raquo.timetracker.tracker accessibilityTreeApps -array notion.id   # added to the built-in list
launchctl kickstart -k gui/$(id -u)/com.raquo.timetracker.tracker   # restart to apply
```

To explore what an app exposes: `open -n -W ~/Applications/TimeTracker.app --args --dump-ax <bundle-id> /tmp/ax.txt`. Writes the tracker's page search on each of the app's windows (elements visited, time, web areas found), then the focused window's Accessibility tree. Switches the app's tree on and leaves it on.

Code layout: `Apps/` holds app-specific code (`Claude.swift`, `Browsers.swift`), `Diagnostics/` the dump tool; the rest is generic.

## Look at the data

```bash
sqlite3 ~/Library/Application\ Support/com.raquo.timetracker/timetracker.db "
  SELECT datetime(i.start_ms / 1000, 'unixepoch', 'localtime') AS start,
         (i.end_ms - i.start_ms) / 1000 AS secs, a.name, t.title, pt.title AS page_title, u.url, p.path,
         w.subrole, i.is_idle, i.is_screen_locked
  FROM tracker_interval i
  LEFT JOIN tracker_app a ON a.id = i.app_id
  LEFT JOIN tracker_title t ON t.id = i.title_id
  LEFT JOIN tracker_title pt ON pt.id = i.page_title_id
  LEFT JOIN tracker_url u ON u.id = i.url_id
  LEFT JOIN tracker_path p ON p.id = i.path_id
  LEFT JOIN tracker_window_role w ON w.id = i.window_role_id
  ORDER BY i.start_ms DESC LIMIT 30"
```
