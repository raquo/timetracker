# Time Tracker — plan

A personal replacement for Timing.app (version 2020.5, getting old): a lightweight macOS activity tracker, a Scala backend, and a web UI for rules, timelines and reports.

- How the tracker gets its data, and what we've learned about specific apps: [tracking-techniques.md](tracking-techniques.md).
- Electron apps and the Claude desktop app (web content tree, page URLs, session files): [electron-and-claude.md](electron-and-claude.md).
- Tracker build, install and data queries: [tracker/README.md](../tracker/README.md).

## Status

**Tracker:** running daily as a LaunchAgent since 2026-11-22, writing to the real database (schema version 5). Data was reset on 2026-11-22 at 20:58 (migration 1 edited in place: `identifier_type` became an integer); edit migrations in place only together with a reset. Records app, window title and kind, document path, page URL and title in apps where probing found content pages (browsers, Claude, …), idle, screen lock and sleep gaps. Not yet: video / call / camera / mic signals, menu bar item, exclusions.

**Server, UI, Timing import:** not started.

### Done so far

- Swift package in `tracker/`, signed with a stable self-signed identity ("Time Tracker"), installed to `~/Applications/TimeTracker.app`, run by launchd (`com.raquo.timetracker.tracker`). Accessibility permission granted and survives rebuilds.
- Schema with migrations (`tracker_schema` version table, so the server can migrate its own tables independently): intervals, lookup tables for apps / titles / paths / URLs / window roles.
- Sampling: app activation and Accessibility events (focused window, window title; for apps whose pages are read also focused element, page title, page load), any click (600 ms later), and a 5 s poll.
- Page URL and title through the web Accessibility tree. Verified on Claude Code sessions and regular chats, Firefox, Safari and Chrome. Since 2026-11-23 adaptive (below): no allowlist, every app is probed.
- Idle: ≥ 60 s without input, backdated to the last input.
- Consistency safeguards: separate writes for close / open, no overlapping rows on backward clock jumps (watermark), single instance per database (`flock`), final sample before quit / sleep.
- `--dump-ax` diagnostic mode to explore what an app exposes, and to measure the tracker's page search in it.
- Browser URLs (2026-11-22): Firefox, Safari and Chrome expose the shown tab's page in the Accessibility tree without any switch, so they go through the same reader as Claude; no Apple Events, no Automation prompts. URL scrubbing (fragment, credentials, secret-looking query parameters; Gmail keeps its view). Settling before recording.
- Adaptive page reading (2026-11-23): every app is probed (one window search on window change and once a minute); a content page seen → on, none in 30 min of active use → off; the user's choice in a server table overrides. Replaced the allowlist and its `accessibilityTreeApps` defaults key.
- Code review pass (2026-11-22): one global 0.5 s Accessibility timeout; shared Accessibility helpers and lookup tables; no page cache (each sample searches afresh, so it never reports a page no longer shown); web content pages told apart from the app's own UI by "loaded from the app's bundle", not by scheme; Claude-specific code in `Apps/Claude.swift`.

## Why not ActivityWatch

Evaluated v0.14.3 (Nov 2026) and rejected it:

- Categories can't match on URL: rules only see the window watcher's `app` and `title`. The browser extensions' `url` is never joined in (open since 2019, aw-webui#151). Most of our Timing rules are domain rules.
- No document/file paths.
- One regex per category is the only rule type.
- Weak UI.

## Architecture

| Piece | Tech | macOS permissions | Runs |
|---|---|---|---|
| **tracker** | Swift app | Accessibility; Automation (planned, for browser URLs) | always (LaunchAgent) |
| **server** | Scala, GraalVM native image | none | always (LaunchAgent), or on demand |
| **UI** | Scala.js | n/a | browser tab (or Safari "Add to Dock") |

- **One SQLite database** (WAL mode): `~/Library/Application Support/com.raquo.timetracker/timetracker.db`. The tracker writes only its raw activity tables (`tracker_*`). The server writes only its own tables (projects, rules, manual edits, caches) and never touches tracker tables (by convention). Each side runs its own migrations on its own tables.
- **Isolation:** tracker and server are separate signed bundles with separate bundle IDs, each launched by launchd as its own LaunchAgent, never by each other. That keeps the server outside the tracker's permission grants. Check: `AXIsProcessTrusted()` in the server returns `false`.
- **Record raw facts, categorize later.** The tracker knows nothing about projects or rules. Rule edits apply to all history.
- The tracker must be lightweight. The server and UI optimise for ease of development.
- **Naming:** booleans are named as such: `is_` / `has_` in SQL, `isX` / `hasX` in code. No generic `value` columns.

### Timestamps

All timestamps are Unix epoch **milliseconds as 64-bit integers**, everywhere: SQLite `INTEGER`, Swift `Int64`, Scala `Long`. Never 32-bit, never seconds in an `Int` (the 2038 rollover is a signed 32-bit seconds problem). Durations likewise.

- **Swift:** get the time from the shared `nowMs()`. Convert from `Double` only after checking `isFinite` (`Int64(Double)` traps on infinity and NaN).
- **Scala JVM:** `Long`, `java.time.Instant` at the edges. Watch for `Int` creeping in through `.toInt`, `Int`-typed case class fields, or `Int` arithmetic on durations.
- **Scala.js:** `Long` works correctly, but it's emulated and slower than `Double`. That's fine for models and codecs; in hot rendering code convert to `Double` (exact up to 2^53 ms, about 285,000 years) on purpose, never to `Int`. `js.Date` takes a `Double`.
- **JSON (borer):** encode as a JSON number. JS `JSON.parse` keeps it exact below 2^53, which ms timestamps are. Test a round trip of a post-2038 value (e.g. `4102444800000`, 2100-01-01) on both JVM and JS.

## Tracker (Swift)

### Requirements

- **No keylogging, ever.** The tracker never records keystrokes or typed text and never installs a keyboard monitor or event tap, not even as a sampling trigger. Input only counts as "time since last input" and "a click happened" (never where or on what).
- **Record raw data generously, for now.** While the tracker is young, capture any cheap raw signal that might help explain or attribute time later: the server can ignore what it doesn't use, but unrecorded history can't be recovered. Only data about *what was on screen*, never *what the user typed*. Weigh each signal against tracker cost and row churn.
- **Privacy is enforced in the tracker, before writing.** Exclusions and URL scrubbing (see TODO) must apply before anything reaches the database; a later cleanup can't un-write the file.
- **Lightweight:** event-driven, a few cheap calls per sample, flush every 30 s.

### What it records

Schema: `tracker/Sources/TrackerCore/Storage/Schema.swift` (the source of truth, with comments).

- **`tracker_interval`**, one row per stretch with identical attributes: `start_ms`, `end_ms`; app; window title; window role (AX role + subrole); document path; page URL and page title (apps whose pages are read); `is_idle`, `is_screen_locked`, `is_main_window`, `is_full_screen`; not yet recorded (NULL = not measured): `has_display_sleep_assertion`, `is_camera_in_use`, `is_mic_in_use`. Sleep and tracker downtime are gaps between rows.
- **`tracker_app`**: one row per (`identifier_type`, `identifier`, `app_path`): `identifier_type` is 0 = bundle ID, or 1 = executable path for processes without one; `app_path` is the `.app` bundle or executable path, so history keeps which copy ran; `name` is the latest display name. "The app" = group by type + identifier.
- **Lookup tables** `tracker_title` (window and page titles), `tracker_path`, `tracker_url`, `tracker_window_role`.

**URL scrubbing (decided and done 2026-11-22, `URLScrubber.swift`):** before recording, every URL loses its fragment, any `user:password@`, and query parameters whose name says they hold a secret (`code`, `key`, `sig`, names containing `token`, `secret`, `password`, `signature`, `session`, `X-Amz-*`, …). Other parameters stay (`?v=`, `?q=`, GitHub's `?state=closed`). Removed parts can't be recovered later.

**URL fragments:** the tracker drops the `#…` part of every URL before recording it. Fragments are usually a position within the page (Notion's `#<block-id>`, heading anchors), which splits rows with no information about what's being worked on, and they can carry secrets (`#access_token=…`). Applies to all URLs, including browser URLs once we record them. Exception: apps that route by fragment keep its first segment, if it's a plain word: Gmail `#inbox/<message-id>` → `#inbox` (the message is in the title). List: `URLScrubber.fragmentRoutedHosts`, so far only `mail.google.com`. Dropped fragments can't be recovered later.

**Idle:** `is_idle = 1` inside a stretch of ≥ 60 s without input, starting at the last input ("backdated"). So the server can apply any away threshold ≥ 60 s to all history: a run of consecutive idle rows is one input-free stretch. **Away rule (first version, server):** no input for N minutes counts as away, unless a display-sleep assertion is held or the camera / mic is in use (videos, calls, presentations).

### Record consistency

**Principle: every row must describe one real moment.** Its attributes belong together, were all true at once, and hold for the whole `[start_ms, end_ms)` span. Rows never overlap. Rules attribute time per row, so a mismatched row (one tab's title next to another tab's URL) is time silently filed under the wrong project, and nothing downstream can detect or repair it.

- **Prefer a short delay over an incomplete or mismatched row.** Transient glitches (a navigation half done, an app switch mid-read) should be handled by waiting for the state to settle and recording it complete, backdated to when the change was first seen. A field is left NULL only when the value really isn't there (e.g. a DevTools window is focused: no tab URL belongs to that title).
- **Double-check reads from multiple sources.** When one snapshot combines separate asynchronous sources (NSWorkspace, Accessibility, Apple Events), verify afterwards that they still agree (same frontmost pid, matching titles).
- **Writes are separate autocommit statements**, not one transaction around "close the previous row, open the next": closing the previous row must not depend on the lookups and insert for the next one. A failure in between leaves a gap, never an overlap or a stale row; a failed close keeps the row open in memory and is retried.

What holds today: each row comes from one snapshot read in one pass; title, kind and document path come from the same window element; URL and page title come from the same page element; WAL gives the server a consistent view.

Known ways to break it:

| # | Issue | Status |
|---|---|---|
| 1 | **Intermediate states during navigation**: a browser commits the new URL before the title updates (or SPAs the other way round), so a sample in between records (title1, url2). Same for in-between states while switching. | Handled for states shorter than ~400 ms: settling (`Settler`) records a change only once a second sample agrees, from when it was first seen. Longer in-between states (the bare-app-name Firefox title, 2–5 s) still get rows. |
| 2 | **Title and URL from different windows / tabs**: window title from one window and URL from another. | Avoided: both come from the focused window, the URL and page title from the same web area. Would matter again with Apple Events (`front window`). |
| 3 | **Non-atomic reads**: app, window and URL are read tens to hundreds of ms apart; the user can switch apps mid-sample. | Open. Fix: re-check the frontmost pid after sampling, else discard and re-sample. |
| 4 | **Late boundaries**: a change is recorded when noticed: ~300 ms after an event, 600 ms after a click, up to 5 s with neither (URL-only changes, idle → active). | Accepted; bounded by the poll interval, so don't raise it lightly. |
| 5 | **Backdated idle rows carry later attributes**: their app / title are from when idle was detected, not from the last input. | Accepted (minor). |
| 6 | **Clock jumps backwards** would make rows overlap. | Handled: watermark (latest closed `end_ms`); while the clock is behind it, the tracker records nothing. UX open (TODO). |
| 7 | **Two tracker instances** writing the same database. | Handled: exclusive `flock` on `<db>.lock`; a second instance exits (launchd retries it). |
| 8 | **The open row's `end_ms` on disk lags** by up to 30 s. | By design; the server must treat the newest row as possibly ongoing (TODO). |
| 9 | **No final sample before sleep**: macOS doesn't wait for apps to handle `willSleep`. | Handled: the first sample after wake sees a gap > 20 s and ends the row at the last sample. Also when a hung app stalls sampling past 20 s (bounded: every Accessibility call times out after 0.5 s). |

### Menu bar item (planned)

- Tracking status, with a warning when Accessibility or Automation permission is missing.
- Pause tracking (1 hour / until resumed).
- "Open Time Tracker": `launchctl kickstart gui/$UID/<server-label>` (so launchd, not the tracker, starts the server), wait for its health check, open the URL in the browser.
- Possibly: clock-jump warnings, the "switch off accessibility trees" question (see TODO).

## Server (Scala → GraalVM native image)

- JDK built-in HTTP server on `127.0.0.1`. Serves the Scala.js bundle and a JSON API (borer). Check the `Host` header and require a token, so other local programs and websites can't use the API.
- Owns all data processing:
  - **Attribution cache:** maps each distinct (app, title, page title, path, url) combination to a project. Rebuilt in full on rule edits; new combinations attributed as they appear. Rules use equals / contains / starts with / ends with on each field, so the rule engine evaluates every rule against every distinct combination, in memory. That stays cheap because it runs over distinct combinations, not intervals. Concern: browser titles make combinations grow with every page visited, so there may be hundreds of thousands; measure on imported Timing data. Title normalization (TODO) shrinks it.
  - **Derived URL parts:** many rules match the domain or subdomain, not the whole URL. A server-owned table, computed once per distinct `tracker_url` row, holds the host and the registrable domain (`news.bbc.co.uk` → `bbc.co.uk`, needs the Public Suffix List). The tracker keeps storing only the full URL.
  - **Daily rollups:** seconds per day × project × app × domain, for fast reports over long ranges. Rebuilt after rule edits.
  - **Manual assignments** (time ranges assigned to a project) override rules, applied at query time.
  - **App-specific context** resolved from other local sources, e.g. Claude session → folder / environment (TODO).
- Idle self-exit (optional): the UI pings while open; the server exits after N minutes without requests. Lets it run on demand via the menu bar instead of always.
- Develop on the JVM; build the native image for releases. Avoid reflection-based libraries.

## UI (Scala.js)

- Projects tree with color and productivity score.
- Rules as lists, not regexes: domain (equals / suffix), app, title contains, path prefix, URL contains. Priority order between projects.
- Timeline day view: activity blocks, unassigned time, assign / split blocks.
- "Make a rule from this activity."
- Reports by project / app / domain over date ranges, with charts.
- Settings: title normalization, privacy exclusions.
- A shared Scala module (JVM + JS) holds API models, borer codecs, and the rule engine, so the rule editor can preview matches live in the browser.

## Timing import

Import history and rules so we don't start from zero.

- DB: `~/Library/Application Support/info.eurocomp.Timing2/SQLite.db` (open read-only: `file:...?mode=ro`).
- History: `AppActivity`, `Application` (`bundleIdentifier`, `title`), `Title`, `Path` (`file://` paths, iTerm cwd, IntelliJ project name, browser URLs), `TaskActivity` (manually assigned time).
- `Project`: `title`, `parentID` (tree), `color` (`#RRGGBBAA`), `productivityScore` (-1..1), `ruleListPosition` (rule priority), `isArchived`, `predicate`.
- `predicate` is a protobuf-encoded `NSPredicate` (inspect with `protoc --decode_raw`). All our rules are a flat OR of comparisons:
  - Compound: field 1 → { 1: type (2 = OR), 2: repeated subpredicates }.
  - Comparison: field 2 → { 1: operator, 3.4.1: key, 4.1: value (1 = string, 2 = int), 5: options (`\x01\x02` = case/diacritic insensitive) }.
  - Operators: 4 = equals, 8 = begins with, 9 = ends with, 10 = in list, 99 = contains.
  - Keys: `webDomain` (388), `applicationID` → `Application.id` (55), `keywords` (9), `path` / `filePath` (6).
- Open question: where imported history lives. Not in tracker tables (only the tracker writes those), so most likely server-owned `timing_*` tables that the server reads alongside `tracker_*`.

## TODO

### Tracker: data capture

- **Browser URLs, follow-ups:** verify Arc, Brave, Edge (listed in `Apps/Browsers.swift`, not tried). Private / incognito windows: record them like any other until exclusions exist (see Privacy). Apple Events stay a fallback if a browser's tree layout breaks.
- **Firefox bare-app-name titles:** rows titled just "Firefox Developer Edition" for 2–5 s now and then while switching between populated tabs, in a standard main window. Settling doesn't catch them (too long). Look at the URL recorded with the next one.
- **Claude gaps:**
  - A session opened in its own window (cmd-click) recorded 6.8 s with the conversation name as window title but no page URL / title. Find out why (tree not built yet in the new window? several web areas?).
  - The browser pane inside a Claude Code session is a nested web area we don't descend into, so pages visited there aren't recorded (time stays on the session). Decide whether to.
- **Video / call / camera / mic:** power assertions (`PreventUserIdleDisplaySleep`), camera and mic in use. Needed by the away rule. Columns already exist.
- **Finder folder** via Apple Events (`target of front window`): Finder leaves `AXDocument` empty.
- **More raw signals** (candidates): role of the focused UI element (text field vs web area), window frame / which display, number of displays, the window's `AXIdentifier`, the app's window count, audio output playing, Focus mode. Beware of signals that change constantly (window frame while dragging) and multiply rows.
- **Fast user switching:** while another macOS user is active, the tracker keeps sampling, and that time is recorded as idle in whatever app was frontmost. Handle `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` like lock / unlock (or as a gap).
- **Generic runtimes, going forward:** if we decide to identify some apps by path (see Server), the tracker could write a new `identifier_type` for a known list; needs a migration to widen the `CHECK` constraint (in SQLite: rebuild the table).

### Tracker: consistency and noise

- **Mismatched samples** (consistency #3 and others): when a double-check fails and the sample is discarded, decide what the discarded span is attributed to: extend the previous row (last known-good state), leave a gap, or record only the fields we're sure of (e.g. app without title / URL). Cap retries.
- **Brief noise rows:** sub-second artifacts, not activity: the first sample after switching on an app's Accessibility tree (built lazily, so no URL yet), in-between states while switching. (Zero-length rows opened by the closing sample on quit / sleep are already deleted.) Avoid writing them where we can tell (e.g. wait for a new tree to be ready), and filter the rest in the server (merge into a neighbour below some duration). Settling drops those shorter than ~400 ms.
- **Clock jump UX:** today the tracker pauses silently (with a log line) while the clock is behind recorded data. Decide how to surface it: a menu bar warning, an offer to pause tracking (e.g. a developer testing time-related code), or discarding rows recorded under the wrong clock. Forward jumps currently just look like a gap.

### Tracker: privacy

- **Sensitive data in URLs and titles:** URLs are scrubbed by a denylist of parameter names (see "URL scrubbing"). Open: secrets in parameters with innocent names, or in the path (magic sign-in links like `/login/<token>`); titles carrying email subjects, document names, chat snippets. Research how other trackers handle it: Timing, RescueTime, Rize, ActivityWatch's browser extensions, Toggl Track's autotracker, Apple Screen Time.
- **Exclusions:** skip tracking for chosen apps, domains (incl. subdomains), title patterns, and private / incognito browser windows; plus pause. Decide per rule whether excluded time is recorded as a bare "excluded" row (time counted, no detail) or as a gap. Enforced in the tracker, so it needs to read a small exclusion config.

### Tracker: Accessibility tree in other apps

- **Adaptive page reading (implemented 2026-11-23, replaced the allowlist; `PageReadingPolicy.swift`).** Instead of a fixed list of apps whose page URL and title we read, every app starts in "auto" and the tracker finds out by itself whether reading pages is worth it there.
  - **Scope:** only the page part (web areas: page URL and title, the switch, the extra observers). Window title, kind and document path stay read for every app, always.
  - **Per-app mode:** auto, on, off. On: search every sample, observers for focus / page title / page load (what allowlisted apps got before). Off: no page reading. Auto: probing, below.
  - **Probing (auto):** one search of the focused window when it isn't the window last probed in that app, and about once a minute, not every sample (kept per app, so switching back to an app doesn't search its window again); no extra observers; rows are recorded without page URL / title meanwhile. Electron apps (detected by `Contents/Frameworks/Electron Framework.framework` in the bundle, so no list) get `AXManualAccessibility` first, since they show nothing without it; every other app is searched without any switch (browsers and native apps with web views expose their pages anyway).
  - **Verdict, from what the probes saw** (content pages as today: not in the app's bundle, not `about:`):
    - On: any content page seen (one URL is enough). Deliberately generous: we don't yet know what document-based apps (LibreOffice, Fusion 360, …) expose, so rather over-sample than miss long-lived documents.
    - Off: no content page seen within the evidence threshold.
    - Refine later (TODO below): apps whose only page is constant and says nothing (Obsidian: `app://obsidian.md/index.html` for every note, page title = window title) get "on" for nothing. Possible refinements: require ≥ 2 distinct URLs or a page title that differs from the window title; keep a browser left on one "What's new" page in auto instead of deciding off.
  - **Evidence threshold:** 30 min of active time (frontmost, not idle, not locked, with a focused window and the Accessibility permission, so a probe could look), within one tracker run (not persisted). Counted by summing the steps between consecutive samples, each capped at ~10 s, so sleep, hangs and wall clock jumps add nothing. Apps used only briefly stay auto, which is why probing must be cheap.
  - **Search budget:** apps with pages need few elements (Firefox 16, Claude 20, Safari 22, Chrome 56), so it's 150 (was 500); it mainly caps the cost of a fruitless search.
  - **Storage, split by who decides,** so neither side writes the other's tables:
    - Names say who decided: the user's side is a *choice*, the tracker's side a *probe result*, never both called "mode" or "enabled". Sketch:
      - Server-owned (written from the UI), `app_page_reading_choice`: `identifier_type`, `identifier`, `page_reading_choice` (0 = auto, 1 = on, 2 = off), `reprobe_requested_at_ms` (nullable). The tracker reads exactly these columns; the server's migration must create the table with them (unique on `identifier_type, identifier`). Until then it can be created by hand (tracker/README.md).
      - Tracker-owned, `tracker_app_page_probe` (migrations 4, 5): `identifier_type`, `identifier`, `has_content_pages` (the probe result, a raw fact: did the app show content pages; NULL = not decided yet), `decided_at_ms`; for debugging, `probe_count`, `first_probe_at_ms`, `last_probe_at_ms`. A row exists from the first probe on; no row = never probed. To avoid a write per probe, the counts are saved on the first probe, on a decision, and on quit / sleep (so a crash loses the counts since the last save, not the result).
    - Effective: the user's choice unless auto, else the probe result, else probing. A re-probe request newer than `decided_at_ms` starts probing again.
    - Keyed like `tracker_app` minus `app_path`: the bundle ID for bundled apps (so moving or updating `Foo.app` keeps its setting), else the full executable path (never a bare name). An unbundled process that moves is a new app and gets probed again, which is the safe side. Caveat, same as "Generic runtimes" (Server): for scripts the executable is the interpreter (`/usr/bin/python3`, or `org.python.python` for a Python GUI), so all scripts run by one interpreter share one setting; telling them apart would need the script path from the process's arguments, which the tracker doesn't read today.
    - The tracker must work while the server's table doesn't exist yet. It notices UI edits by checking `PRAGMA data_version` each sample and re-reading settings only when it changed. Exclusions (Privacy) would use the same pattern: settings that change tracking live in server tables the tracker only reads.
  - **UI:** per app, show the effective mode and where it came from (your choice, or the verdict and when); let the user set auto / on / off and request a re-probe.
  - **Known costs and limits:**
    - Probing an Electron app switches its tree on for the rest of its run, also when the verdict is off (we don't switch it off, see below). Some apps react (VS Code: "Screen reader usage detected" popup).
    - An app briefly showing a web page (a sign-in window, a "What's new" panel) flips to on for good; the user can set it off in the UI. A probe result of off lasts until re-probed, though app updates can add web views. Optional: re-probe when the app's path changes.
    - Probing reads pages in apps that so far only had window titles recorded (password managers, banking apps, Mail): scrubbing applies, but exclusions become more pressing.
  - **Later:** seed known browsers (`Apps/Browsers.swift`) and Claude to on, so they skip the probe. Refine the "on" condition (Obsidian, above) once we have probe results from real apps.
- **Browsers' tree is on anyway (observed 2026-11-23):** with the tracker stopped, Firefox's `about:support` showed accessibility off right after launch and "Activated" a few seconds later, before any page reload. Some other app with Accessibility access (likely a window manager such as Rectangle) turns it on. So on this Mac, reading browser pages adds no browser-side cost. Doesn't apply to Electron apps, whose tree needs `AXManualAccessibility`, probably set only by us.

- **Switching it off.** The tracker switches on `AXManualAccessibility` in Electron apps it reads or probes and never switches it off, so the app keeps paying for the tree until it quits. Switching it off on quit isn't safe: another assistive app (or the user) may have started relying on it while we ran, and we can't tell; checking whether it was on before we started doesn't solve that (and Electron reports the flag as false even while it's on, so we can't even check). A force-killed or crashed tracker can't switch anything off, and the next run then finds it on and can't tell whether it was ours. Options: ask the user on quit (quitting the tracker is rare), but never block a logout / shutdown with that prompt (skip it when the system initiates the quit); remember in a file which pids we switched on, so the next run after a crash can decide; or accept leaving it on. Undecided.
- **Measure its cost:** Claude's CPU (renderer and main process) and memory with the tree off vs on, a few minutes each, idle and while a long reply streams; (browsers: not needed here, their tree is on anyway, see below); plus the tracker's own cost per sample for apps whose pages are read (measured part: finding the page in Claude's window, done on every sample, visits 20 elements in 4–17 ms, the same while Claude streams a reply; so the tracker doesn't cache it). Decide whether reading Electron apps' pages is acceptable for daily use.

### Server

- **Open row lag:** the newest `tracker_interval` row's `end_ms` can be up to 30 s behind (flush interval). Treat it as possibly ongoing: in "today" totals and the live timeline, extend it to now if it ended within the flush interval; don't cache rollups for the current period as final.
- **Title normalization (user option):** many title changes are noise: unread counts (`Inbox (3)`, `(12) Slack`), notification flashing (seen 2026-11-22: Gmail alternating its tab title with "Google Drive messaged you - Chat" every 2 s, ~70 rows in 2.5 minutes; settling can't help, each state lasts 2 s), now-playing tracks, progress percentages. Each makes a new row and a new distinct title, fragmenting the timeline and multiplying attribution combinations. Normalize before attribution and display: strip counters like `(3)` / `[3]` / `• `, collapse known patterns; global on/off, maybe per-app patterns. The tracker keeps raw titles, so normalization can change and apply to all history. Measure how much it shrinks the distinct-title count. Careful: two different titles can be two genuinely different things (e.g. two Gmail accounts' inboxes), only the counter is noise.
- **Claude session context:** a Claude Code page URL (`claude.ai/epitaxy/local_<id>`) maps to the desktop app's session file `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`: `cwd` (→ project), `title`, `cliSessionId` (→ the transcript in `~/.claude/projects/`) and `envScopeId`, which `ccd-session-presets.json` maps to the environment name (e.g. "⏰ TIME TRACKER"). Resolve this read-only in the server; we deliberately don't scrape Claude's UI for it. Undocumented internal files: tolerate missing or changed fields, cache resolved sessions (deleted sessions' files get renamed `deleted_<id>`). Regular chats (`claude.ai/chat/<uuid>`) have no such file; the page title is what we have.
- **Claude Code hooks / transcripts (optional):** transcripts in `~/.claude/projects/` have timestamped messages and `cwd`, including history from before the tracker; hooks (`SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`) could append `{time, event, session_id, cwd}` to a JSONL file. Both show activity per session, not which session is visible, so with the page URL recorded they're mainly for older history. Keep them out of tracker tables.
- **Generic runtimes:** some bundle IDs cover many unrelated apps: `org.python.python` (any Python GUI script), `com.github.Electron` (any Electron app run from source), maybe Java launchers. Decide whether to identify them by `app_path` instead. Retroactive: `tracker_app` rows are already per path. Prefer a server-side mapping (`tracker_app.id` → logical app) over rewriting tracker tables. The script itself (`foo.py`) isn't in the path, only the runtime's; the window title would have to tell scripts apart.
- **Structured app data (idea):** extract app-specific fields from the raw title / URL / path, so rules can match on meaning instead of string patterns: "Slack workspace = ClubLocarno", "channel = windsurf-repairs", "Notion page = <id>", "Obsidian vault = Notes", "VS Code folder", "GitHub repo", "Jira issue key", "Claude session folder / environment". Per-app extractors, e.g. Slack: title `<channel> (Channel) - <workspace> - Slack` and URL `/client/<team-id>/<channel-id>` (IDs survive renames); Obsidian: title `<note> - <vault> - Obsidian <version>`, vault path from Obsidian's `obsidian.json`; Notion: page ID from `/p/<slug>-<id>`. Run in the server over distinct (app, title, url, path) combinations, like attribution, so extractors can be added or fixed later and applied to all history. Only data that can't be derived later (e.g. Claude's session files, which change) needs the tracker to capture it at the time. The UI then offers these fields in the rule editor. The Claude and IntelliJ items below are instances of this.
- **IntelliJ projects:** `AXDocument` is empty; the window title is `project – file` (e.g. `timetracker – .gitignore`). Parse it, or read project paths from the IDE's recent-projects config.

### Research

- **Timing's granularity:** look at `AppActivity` start / end times in Timing's DB to find the shortest intervals it keeps and how it rounds or merges them. Use that to decide how to filter or merge short rows in reports, and to know how our totals will compare when validating against Timing.
- **Other trackers' URL handling:** see "Sensitive data in URLs and titles".

## Order of work and rough size

1. **Tracker** (in progress): ~1.3–1.9k LOC. Collecting since 2026-11-22. Next: consistency checks (#3), privacy (exclusions), menu bar item, video / call signals. Validate by running alongside Timing and comparing daily totals.
2. **Timing import:** ~200–400 LOC, 1–3 days.
3. **Server + UI:** ~4–8k LOC, ~5–10 weeks. Mostly ordinary UI work.

The tracker is useful on its own: data accumulates in our own format even before the UI exists.
