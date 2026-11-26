# Time Tracker: activity tracker

A Swift agent without a menu bar item that records raw activity into `~/Library/Application Support/com.raquo.timetracker/timetracker.db`. This file covers building, running and inspecting it.

- What it records and what the tables mean: [docs/data-model.md](../docs/data-model.md).
- The rules it follows: [docs/tracker-principles.md](../docs/tracker-principles.md). How it fits with the server: [docs/architecture.md](../docs/architecture.md).
- Topics not yet moved into docs (sampling and settling, URL scrubbing, idle, consistency): [notes/PLAN.md](../notes/PLAN.md), [tracking-techniques.md](../notes/tracking-techniques.md), [electron-and-claude.md](../notes/electron-and-claude.md).

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

The tracker records the URL and title of the page in the focused window (`page_url_id`, `page_title_id`), read from the app's web Accessibility tree, in apps where that's worth it. Which apps is decided per app (`PageReadingPolicy.swift`, "Adaptive page reading" in `../notes/PLAN.md`):

- **Probing:** an app nobody has decided on gets one search of its focused window when that's a window not probed last in the app, and about once a minute, recording no page meanwhile. Electron apps (they ship `Electron Framework.framework`) get their tree switched on first (`AXManualAccessibility`), which costs them some CPU and memory until they quit; browsers and other apps expose their pages without a switch.
- **Probe result** (`tracker_app_page_probe`): a content page seen → on (page read on every sample, with observers); none seen in 30 min of active use (with a focused window to probe) within one run → off. A row appears at an app's first probe (`has_content_pages` NULL until decided), with `probe_count` and first / last probe times, saved on the first probe, on a decision, and on quit / sleep.
- **Your choice** overrides it: the server-owned table `app_page_reading_choice`, which the tracker only reads, and re-reads when another process writes to the database. Until the server and UI exist, create it by hand:

```bash
sqlite3 ~/Library/Application\ Support/com.raquo.timetracker/timetracker.db <<'SQL'
CREATE TABLE IF NOT EXISTS app_page_reading_choice (
    identifier_type         INTEGER NOT NULL,  -- 0 = bundle ID, 1 = executable path
    identifier              TEXT NOT NULL,
    page_reading_choice     INTEGER NOT NULL,  -- 0 = auto (probe result), 1 = on, 2 = off
    reprobe_requested_at_ms INTEGER,           -- newer than the probe result: probe again
    PRIMARY KEY (identifier_type, identifier)
);
INSERT OR REPLACE INTO app_page_reading_choice VALUES (0, 'md.obsidian', 2, NULL);
SQL
```

To explore what an app exposes: `open -n -W ~/Applications/TimeTracker.app --args --dump-ax <bundle-id> /tmp/ax.txt`. Writes the tracker's page search on each of the app's windows (elements visited, time, web areas found), then the focused window's Accessibility tree. Switches the app's tree on and leaves it on. With the wrong arguments it prints the usage and exits with 2, rather than starting to track.

## Code layout

- `Sources/TimeTracker/main.swift`: the executable, only calls `TrackerMain.run` in `TrackerCore`.
- `Sources/TrackerCore/`: everything else, a library so tests can import it.
  - `App/`: entry point and command line (`TrackerMain`), event wiring (`Tracker`), instance lock, logging.
  - `Sampling/`: what's on screen now (`Sampler` → `Snapshot`), and holding back unconfirmed changes (`Settler`).
  - `Recording/`: snapshots into `tracker_interval` rows: the row logic (`Recorder`) and its SQL (`IntervalStore`).
  - `PageReading/`: finding the page in a window (`PageSearch`, pure tree reads), deciding per app whether to read pages (`PageReadingPolicy`) and its tables (`PageReadingStore`).
  - `Accessibility/`: `AXUIElement` reads and the `AccessibilityNode` protocol, change notifications (`WindowObserver`), switching Electron trees on.
  - `Storage/`: SQLite wrapper, schema migrations, lookup tables.
  - `Privacy/`: `UrlScrubber`.
  - `Apps/`: app-specific code (`Claude.swift`; `Browsers.swift`, not used yet). `Diagnostics/`: the `--dump-ax` tool.
- `Tests/TrackerCoreTests/`: `swift test` (Swift Testing; works with the Command Line Tools, no Xcode needed).
  `Support/` holds a temporary migrated database and harnesses that drive `Recorder` (directly, or through `Settler` like `Tracker.tick`) and `PageReadingPolicy` (like `Sampler`) with times relative to `t0`. Tests compare whole stored rows, read back with lookups resolved, and every read checks that rows never overlap. `RecorderHarness.closeInterval` takes a last sample before closing, like `Tracker.closeInterval`. `FakeNode` is a hand-built Accessibility element, so `PageSearch` runs without a live app. Failed writes are simulated with a TEMP trigger that raises an error (`TempDatabase.failWrites`), so no mocks. Use `withKnownIssue` to pin a known gap (stating the wanted result), so fixing it shows up as a test to update.

Seams for tests: the pure parts take time as `atMs` arguments (`Settler`, `Recorder`, `PageReadingPolicy`) and run on a temporary SQLite file; `PageSearch` runs on any `AccessibilityNode`, so on recorded trees as well as live `AXUIElement`s. `Sampler`, `Tracker` and `WindowObserver` talk to macOS directly and are left to end-to-end runs.

## Look at the data

```bash
sqlite3 ~/Library/Application\ Support/com.raquo.timetracker/timetracker.db "
  SELECT datetime(i.start_ms / 1000, 'unixepoch', 'localtime') AS start,
         (i.end_ms - i.start_ms) / 1000 AS secs, a.name, t.title, pt.title AS page_title, u.url, p.path,
         w.subrole, i.is_input_idle, i.is_screen_locked
  FROM tracker_interval i
  LEFT JOIN tracker_app a ON a.id = i.app_id
  LEFT JOIN tracker_title t ON t.id = i.title_id
  LEFT JOIN tracker_title pt ON pt.id = i.page_title_id
  LEFT JOIN tracker_url u ON u.id = i.page_url_id
  LEFT JOIN tracker_path p ON p.id = i.document_path_id
  LEFT JOIN tracker_window_role w ON w.id = i.window_role_id
  ORDER BY i.start_ms DESC LIMIT 30"
```
