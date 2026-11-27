# Time Tracker: activity tracker

A Swift agent without a menu bar item that records raw activity into `~/Library/Application Support/com.raquo.timetracker/timetracker.db`. This file covers building, running and inspecting it.

- What it records and what the tables mean: [docs/data-model.md](../docs/data-model.md).
- The rules it follows: [docs/tracker-principles.md](../docs/tracker-principles.md). How it fits with the server: [docs/architecture.md](../docs/architecture.md).
- When it samples, idle and lock, consistency: [docs/sampling.md](../docs/sampling.md), [docs/idle-and-away.md](../docs/idle-and-away.md), [docs/record-consistency.md](../docs/record-consistency.md).
- Privacy: [docs/privacy.md](../docs/privacy.md); URL scrubbing: [docs/url-scrubbing.md](../docs/url-scrubbing.md). The dump tool, fixtures and replay tests: [docs/diagnostics.md](../docs/diagnostics.md).
- Research not yet moved into docs: [tracking-techniques.md](../notes/tracking-techniques.md), [electron-and-claude.md](../notes/electron-and-claude.md).

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

How the tracker decides per app whether to read pages: [docs/page-reading.md](../docs/page-reading.md). The user's choice overrides its probe result, and lives in the server-owned table `app_page_reading_choice`. Until the server and UI exist, create it by hand:

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

To explore what an app exposes: `open -n -W ~/Applications/TimeTracker.app --args --dump-ax <bundle-id> /tmp/ax.txt`. With `--json` after the output file, it instead records the focused window as a test fixture (see `tracker/Tests/TrackerCoreTests/Fixtures/README.md`). What it writes, and how to check a new app with it: [docs/diagnostics.md](../docs/diagnostics.md). To see which Accessibility notifications an app sends as things change: `--watch-ax <bundle-id or pid> /tmp/watch.txt <seconds>`, same doc.

## Code layout

- `Sources/TimeTracker/main.swift`: the executable, only calls `TrackerMain.run` in `TrackerCore`.
- `Sources/TrackerCore/`: everything else, a library so tests can import it.
  - `App/`: entry point and command line (`TrackerMain`), event wiring (`Tracker`), instance lock, logging.
  - `Sampling/`: what's on screen now (`Sampler` → `Snapshot`), presence signals (`PresenceReader` → `PresenceSignals`), and holding back unconfirmed changes (`Settler`).
  - `Recording/`: snapshots into `tracker_interval` rows: the row logic (`Recorder`) and its SQL (`IntervalStore`).
  - `PageReading/`: finding the page in a window (`PageSearch`, pure tree reads), deciding per app whether to read pages (`PageReadingPolicy`) and its tables (`PageReadingStore`).
  - `Accessibility/`: `AXUIElement` reads and the `AccessibilityNode` protocol, change notifications (`WindowObserver`), switching Electron trees on.
  - `Storage/`: SQLite wrapper, schema migrations, lookup tables.
  - `Privacy/`: `UrlScrubber`.
  - `Apps/`: app-specific code (`Claude.swift`; `Browsers.swift`, not used yet). `Diagnostics/`: the `--dump-ax` and `--watch-ax` tools.
- `Tests/TrackerCoreTests/`: `swift test` (Swift Testing; works with the Command Line Tools, no Xcode needed).
  `Support/` holds a temporary migrated database and harnesses that drive `Recorder` (directly, or through `Settler` like `Tracker.tick`) and `PageReadingPolicy` (like `Sampler`) with times relative to `t0`. Tests compare whole stored rows, read back with lookups resolved, and every read checks that rows never overlap. `RecorderHarness.closeInterval` takes a last sample before closing, like `Tracker.closeInterval`. `FakeNode` is a hand-built Accessibility element, so `PageSearch` runs without a live app. Failed writes are simulated with a TEMP trigger that raises an error (`TempDatabase.failWrites`), so no mocks. Use `withKnownIssue` to pin a known gap (stating the wanted result), so fixing it shows up as a test to update.
- `Sources/E2ETarget/`, `Sources/E2EHelper/`, `Tests/TrackerE2ETests/`: the end-to-end tests, run by `scripts/e2e.sh` (all) or `scripts/e2e.sh chrome` (one, by name), and skipped by a plain `swift test`. They need a one-time Accessibility grant for `build/e2e/E2E Helper.app`; without it the script stops and says how. See [docs/end-to-end-tests.md](../docs/end-to-end-tests.md).

Seams for tests: the pure parts take time as `atMs` arguments (`Settler`, `Recorder`, `PageReadingPolicy`) and run on a temporary SQLite file; `PageSearch` runs on any `AccessibilityNode`, so on recorded trees as well as live `AXUIElement`s. `Sampler`, `Tracker` and `WindowObserver` talk to macOS directly and are left to the end-to-end test.

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
