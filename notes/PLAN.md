# Time Tracker — plan

Progress, open questions and ideas. What the app does and why, as built: [docs/](../docs/README.md). Research notes, until they move into docs: [tracking-techniques.md](tracking-techniques.md), [electron-and-claude.md](electron-and-claude.md). Tracker build, install and data queries: [tracker/README.md](../tracker/README.md).

## Status

**Tracker:** running daily as a LaunchAgent since 2026-11-22, writing to the real database (schema version 5). Data was reset on 2026-11-22 at 20:58 (migration 1 edited in place: `identifier_type` became an integer; policy: [docs/conventions.md](../docs/conventions.md)). Records app, window title and kind, document path, page URL and title in apps where probing found content pages (browsers, Claude, …), idle, screen lock and sleep gaps. Not yet: video / call / camera / mic signals, menu bar item, exclusions.

**Server, UI, Timing import:** not started.

### Done so far

- Swift package in `tracker/`, signed with a stable self-signed identity ("Time Tracker"), installed to `~/Applications/TimeTracker.app`, run by launchd (`com.raquo.timetracker.tracker`). Accessibility permission granted and survives rebuilds.
- Schema with migrations (`tracker_schema` version table, so the server can migrate its own tables independently): intervals, lookup tables for apps / titles / paths / URLs / window roles.
- Sampling: app activation and Accessibility events (focused window, window title; for apps whose pages are read also focused element, page title, page load), any click (600 ms later), and a 5 s poll.
- Page URL and title through the web Accessibility tree. Verified on Claude Code sessions and regular chats, Firefox, Safari and Chrome. Since 2026-11-23 adaptive ([docs/page-reading.md](../docs/page-reading.md)): no allowlist, every app is probed.
- Idle: ≥ 60 s without input, backdated to the last input.
- Consistency safeguards: separate writes for close / open, no overlapping rows on backward clock jumps (watermark), single instance per database (`flock`), final sample before quit / sleep.
- `--dump-ax` diagnostic mode to explore what an app exposes, and to measure the tracker's page search in it ([docs/diagnostics.md](../docs/diagnostics.md)).
- Browser URLs (2026-11-22): Firefox, Safari and Chrome expose the shown tab's page in the Accessibility tree without any switch, so they go through the same reader as Claude; no Apple Events, no Automation prompts. URL scrubbing (fragment dropped, Gmail keeps its view; credentials and secret-looking parameter values redacted). Settling before recording.
- Adaptive page reading (2026-11-23): every app is probed (one window search on window change and once a minute); a content page seen → on, none in 30 min of active use → off; the user's choice in a server table overrides. Replaced the allowlist and its `accessibilityTreeApps` defaults key.
- Code review pass (2026-11-22): one global 0.5 s Accessibility timeout; shared Accessibility helpers and lookup tables; no page cache (each sample searches afresh, so it never reports a page no longer shown); web content pages told apart from the app's own UI by "loaded from the app's bundle", not by scheme; Claude-specific code in `Apps/Claude.swift`.

## Tracker (Swift)

Principles (no keylogging, record generously, privacy before writing, lightweight): [docs/tracker-principles.md](../docs/tracker-principles.md).

### What it records

Tables and what they mean: [docs/data-model.md](../docs/data-model.md). URL scrubbing and fragments: [docs/url-scrubbing.md](../docs/url-scrubbing.md). Not moved yet:

**Idle and lock:** [docs/idle-and-away.md](../docs/idle-and-away.md). **Away rule (first version, server, planned):** no input for N minutes counts as away, unless a display-sleep assertion is held or the camera / mic is in use (videos, calls, presentations).

### Record consistency

How it's kept, and the table of known ways to break it with each one's status: [docs/record-consistency.md](../docs/record-consistency.md). When to sample, settling, sleep: [docs/sampling.md](../docs/sampling.md). Open items are in TODO below ("Tracker: consistency and noise").

### Menu bar item (planned)

- Tracking status, with a warning when Accessibility or Automation permission is missing.
- Pause tracking (1 hour / until resumed).
- "Open Time Tracker": `launchctl kickstart gui/$UID/<server-label>` (so launchd, not the tracker, starts the server), wait for its health check, open the URL in the browser.
- Possibly: clock-jump warnings, the "switch off accessibility trees" question (see TODO).

## Server (Scala → GraalVM native image)

- JDK built-in HTTP server on `127.0.0.1`. Serves the Scala.js bundle and a JSON API (borer). Security: [docs/architecture.md](../docs/architecture.md).
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
  - **Pop-out windows (⌘-click a chat or session) have no conversation URL.** Verified with the dump tool, 2026-11-26 (fixture `claude-cmd-click-window.json`):
    - **What the window exposes:** window title = the conversation's name ("Greeting"); one web area, `AXURL` `about:blank`, `AXTitle` = the name (no " - Claude" suffix), focus inside it. None of its ~40 attributes, its links or its DOM ids hold the conversation ID (one DOM id holds a message UUID, not the conversation's). The "Open in main window" button carries no URL.
    - **What we record:** the window title only. `about:blank` isn't content, so no URL and no page title (the page title would only repeat the window title).
    - **Why (inferred):** the main window's page opens the pop-out with `window.open` and renders into it, so the URL belongs to the opener, not to the pop-out. Details and how to confirm: "⌘-click windows" in [electron-and-claude.md](electron-and-claude.md).
    - **Workarounds, app-specific, all in the server** (preferred: Claude's local files over its UI, like the session context below):
      1. **Code sessions by name:** `claude-code-sessions/<account>/<org>/local_<id>.json` has each session's `title`, so window title → `local_<id>` → `cwd`. Works for sessions never shown in the main window. Ambiguous when two sessions share a name; titles can be renamed (match against the title at the time if the file keeps history, else the current one).
      2. **Chats by name:** match the window title against page titles of chats recorded in the main window (`<name> - Claude` with URL `claude.ai/chat/<id>`). Fails for chats never shown there and for duplicate names. Mark the result as inferred.
      3. **Claude's local storage (checked 2026-11-26):** `window-state.json` holds only the main window's frame (position, size, maximized, full screen, display bounds), nothing about pop-outs or conversations. The conversation ID does appear in `Session Storage/` (Chromium LevelDB, partly compressed): UI state keyed by chat ID and a recent-items list with `/chat/<id>` hrefs and titles. `sessionStorage` is per page, so the pop-out may have a namespace of its own naming its conversation, but which namespace belongs to which window is unknown. Undocumented, may change with any update, and full of other private data: last resort.
    - Then decide whether the tracker should record anything more for these windows (e.g. the web area title as page title, to tell a pop-out conversation apart from other Claude windows).
  - The browser pane inside a Claude Code session is a nested web area we don't descend into, so pages visited there aren't recorded (time stays on the session). Decide whether to.
- **Video / call / camera / mic:** power assertions (`PreventUserIdleDisplaySleep`), camera and mic in use. Needed by the away rule. Columns already exist.
- **Finder folder** via Apple Events (`target of front window`): Finder leaves `AXDocument` empty, so today Finder rows have only the window title (usually the folder's name, not its path). Costs: the Automation prompt for Finder, and Apple Events' fit with the rest of a sample (no change events, a separate read of a possibly different window; "Why Apple Events fit poorly" in [tracking-techniques.md](tracking-techniques.md)). Check that `front window` is the focused window (compare names), and time out.
- **More raw signals** (candidates): role of the focused UI element (text field vs web area), window frame / which display, number of displays, the window's `AXIdentifier`, the app's window count, audio output playing, Focus mode. Beware of signals that change constantly (window frame while dragging) and multiply rows.
- **Fast user switching:** while another macOS user is active, the tracker keeps sampling, and that time is recorded as idle in whatever app was frontmost. Handle `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` like lock / unlock (or as a gap).
- **Generic runtimes, going forward:** if we decide to identify some apps by path (see Server), the tracker could write a new `identifier_type` for a known list; needs a migration to widen the `CHECK` constraint (in SQLite: rebuild the table).

### Tracker: consistency and noise

- **Mismatched samples** (consistency #3 in [docs/record-consistency.md](../docs/record-consistency.md), and others): re-check the frontmost pid after sampling, and discard and re-sample if it changed. When a double-check fails and the sample is discarded, decide what the discarded span is attributed to: extend the previous row (last known-good state), leave a gap, or record only the fields we're sure of (e.g. app without title / URL). Cap retries.
- **Brief noise rows:** sub-second artifacts, not activity: the first sample after switching on an app's Accessibility tree (built lazily, so no URL yet), in-between states while switching. (Zero-length rows opened by the closing sample on quit / sleep are already deleted.) Avoid writing them where we can tell (e.g. wait for a new tree to be ready), and filter the rest in the server (merge into a neighbour below some duration). Settling drops those shorter than ~400 ms.
- **Retry missed Accessibility subscriptions** (`WindowObserver`): if adding a notification fails (e.g. an app that has only just launched and isn't answering Accessibility yet), it isn't retried while that app stays frontmost, so its window and title changes are caught only by the 5 s poll until the user switches away and back. Check `AXObserverAddNotification`'s result and retry on the next sample (for the focused window's title subscription too).
- **A sleep that never wakes the tracker:** after `willSleep` the tracker records nothing until `didWake`. If macOS ever posts the first without the second (a sleep that's cancelled or fails), recording stops silently until the next sleep. Not seen; unknown whether it can happen. Safety net if it does: treat a click or an app activation while "asleep" as a wake (the user is clearly there; dark wakes for Power Nap have neither), and log it.
- **Check: does a Touch ID unlock count as input?** Lock the screen, wait over a minute without touching anything, unlock with Touch ID, then look at the row after the unlock. Idle means macOS's idle timer (`CGEventSource.secondsSinceLastEventType`) doesn't count Touch ID, so such unlocks take the "unlock without input" path (handled since 2026-11-23: the locked row stays locked, the idle row starts at the unlock). Either way, note the answer here.
- **Clock jump UX:** today the tracker pauses silently (with a log line) while the clock is behind recorded data. Decide how to surface it: a menu bar warning, an offer to pause tracking (e.g. a developer testing time-related code), or discarding rows recorded under the wrong clock. Forward jumps currently just look like a gap.

### Tracker: privacy

What's built: [docs/privacy.md](../docs/privacy.md). Open items:

- **Sensitive data in URLs and titles:** URL values are redacted by a denylist of parameter names ([docs/url-scrubbing.md](../docs/url-scrubbing.md), which also lists what gets through). Open: secrets in parameters with innocent names, or in the path (magic sign-in links like `/login/<token>`); titles carrying email subjects, document names, chat snippets. Research how other trackers handle it: Timing, RescueTime, Rize, ActivityWatch's browser extensions, Toggl Track's autotracker, Apple Screen Time.
- **Google Calendar event IDs:** kept (decided, [docs/url-scrubbing.md](../docs/url-scrubbing.md#decided-exceptions)). Revisit if recorded data is ever shared or exported, or if `isEmailAddress` should learn to look inside base64.
- **Per-site exceptions to URL scrubbing:** let chosen parameters through for a domain or URL pattern where the denylist redacts something useful (e.g. a `key` or `code` parameter that names a document or a view, not a secret). Like exclusions, a server table the tracker reads.
- **Web addresses in `AXDocument`:** scrubbed since 2026-11-23 ([docs/url-scrubbing.md](../docs/url-scrubbing.md#window-documents-axdocument)). Rows recorded before still hold the raw URLs (8 paths on the dev Mac); clean up by hand if wanted. Still worth a look: which other apps report a non-file `AXDocument` (`SELECT DISTINCT path FROM tracker_path WHERE path NOT LIKE '/%'`).
- **Strip tracking parameters:** `utm_*`, `fbclid`, `gclid`, `mc_eid`, `ref_src` and the like say nothing about what's being worked on but split one page into several URLs. Consider removing them in `UrlScrubber` (they're kept today).
- **Exclusions:** skip tracking for chosen apps, domains (incl. subdomains), title patterns, and private / incognito browser windows; plus pause. Decide per rule whether excluded time is recorded as a bare "excluded" row (time counted, no detail) or as a gap. Enforced in the tracker, so it needs to read a small exclusion config.
- **Sensitive data the UI doesn't show (decide, then maybe make it a principle).** Some recorded data may never be shown: rows the server filters out (sub-second noise rows, [docs/sampling.md](../docs/sampling.md) "Limitations"), lookup rows no interval uses, raw titles hidden behind normalized ones, fields no view displays. Such rows can still hold a secret title or URL the user can't see, so can't find or delete. Position (to confirm): the app shouldn't hold sensitive data that the user can't reach by some means. Options: make everything reachable (a raw-data view, search over all of it, and deletion from there), don't keep what won't be shown (have the tracker skip it, or delete it once filtered), or both. Once decided, consider making it a tracker principle on par with no keylogging ([docs/tracker-principles.md](../docs/tracker-principles.md)). Related: the next item.
- **Deleting tracked data, and cleaning up lookup rows:** once users can delete recorded time (e.g. for privacy), lookup rows (`tracker_title`, `tracker_url`, `tracker_path`, `tracker_window_role`, maybe `tracker_app`) that no remaining interval uses should be deleted too, or the secret title or URL stays in the database. Also decide who deletes: only the tracker writes tracker tables (docs/architecture.md), so either the server asks through a table the tracker reads (like settings), or deletion becomes a documented exception. Afterwards `VACUUM` (or `secure_delete`), since deleted data lingers in free pages and the WAL.

### Tracker: cost

- **Measure and document the tracker's system load,** as a whole and per source: how often it calls which APIs (Accessibility reads per sample, page searches, observers, idle and lock checks) and what each costs; how often and how much it writes to disk (inserts, the 30 s end-of-row flush, lookup inserts, WAL growth and checkpoints, probe saves); its CPU, memory and energy impact over a normal day (Activity Monitor's Energy tab, `powermetrics`, `fs_usage` for writes). Write the result into docs as the tracker's cost budget, and re-measure after changes to sampling. The Electron tree's cost to other apps is a separate item ("Measure its cost" below).
- **Detect slow and misbehaving apps, and tell the user.** Every Accessibility call times out after 0.5 s ([docs/sampling.md](../docs/sampling.md)), which keeps a hung app from stalling the tracker but hides that anything went wrong. Log and count, per app, timeouts, slow samples (total time per sample, page search time), failed subscriptions and other errors. Surface apps that hit them often (menu bar item, server UI), with possible mitigations: relax the time limit for that app, switch off finer-grained reads there (page reading, focus observers), sample it less often, or exclude it. Also useful in reverse: an app made slow *by* the tracker (an Electron tree switched on).

### Tracker: Accessibility tree in other apps

How page reading works (finding the content page, the page reading mode and probing, the Electron switch, cost): [docs/page-reading.md](../docs/page-reading.md). Open items:

- **Refine the "on" condition.** Apps whose only page is constant and says nothing get "on" for nothing: Obsidian (`app://obsidian.md/index.html` for every note, page title = window title), Zoom (its own UI at `https://new-home-page.localhost/index.html`). A rule on scheme or host can't tell these apart (see "Why" in the doc); refine on what the pages do instead. Possible: require ≥ 2 distinct URLs, or a page title that differs from the window title; keep a browser left on one "What's new" page probing instead of deciding off. Related: browsers' own pages (`chrome://new-tab-page/`, Firefox's `about:newtab` and dialogs such as `chrome://mozapps/content/handling/permissionDialog.xhtml`) are recorded on purpose; the server may want to treat them as "no page".
- **Seed known browsers and Claude to on** (`Apps/Browsers.swift`), so they skip the probe.
- **Re-probe when an app's path changes** (optional), since updates can add web views.
- **UI:** per app, show the effective mode and where it came from (your choice, or the probe result and when); let the user set auto / on / off and request a re-probe.
- **Switching it off** ([docs/page-reading.md](../docs/page-reading.md), "The Electron tree switch"). The tracker switches on `AXManualAccessibility` in Electron apps it reads or probes and never switches it off, so the app keeps paying for the tree until it quits. Switching it off on quit isn't safe: another assistive app (or the user) may have started relying on it while we ran, and we can't tell; checking whether it was on before we started doesn't solve that (and Electron reports the flag as false even while it's on, so we can't even check). A force-killed or crashed tracker can't switch anything off, and the next run then finds it on and can't tell whether it was ours. Options: ask the user on quit (quitting the tracker is rare), but never block a logout / shutdown with that prompt (skip it when the system initiates the quit); remember in a file which pids we switched on, so the next run after a crash can decide; or accept leaving it on. Undecided.
- **Measure its cost:** Claude's CPU (renderer and main process) and memory with the tree off vs on, a few minutes each, idle and while a long reply streams; (browsers: usually not needed, their tree is often on anyway; "Background" in the doc); plus the tracker's own cost per sample for apps whose pages are read (measured part: finding the page in Claude's window, done on every sample, visits 20 elements in 4–17 ms, the same while Claude streams a reply; so the tracker doesn't cache it). Decide whether reading Electron apps' pages is acceptable for daily use.

### Tracker: end-to-end tests (layer 3)

Built: [docs/end-to-end-tests.md](../docs/end-to-end-tests.md). Open items:

- **Browsers:** run Chrome and Firefox as separate instances with throwaway profiles (`--user-data-dir`, `-profile … -no-remote`), beside the user's, killed by PID afterwards; drive them through the test pages themselves (a script in the page asks the test what to do next), never keystrokes.
- **Driven tests for Electron apps (Notion, Claude, Slack):** they allow one running copy, so a test run can't start its own the way it does for Chrome and Firefox (a separate instance with a throwaway profile), and driving the user's copy would change their pages. Generalize the user's `claude-fixer` script, which runs a second Claude instance, to more instances and maybe to other Electron apps. Logging in to a fresh instance stays a manual step. Bigger task, later; until then these apps are covered by the recorded trees (layer 2).
- **Keep the real tracker from recording test runs** (low priority): today it runs alongside the test tracker (the instance lock is per database) and records the run's activity into the real database. Once a user-facing "pause tracking" feature exists (see Privacy, exclusions), the test script should switch it on for the run and off again afterwards.

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
- **Existing URL redaction tools:** our scrubbing rules ([docs/url-scrubbing.md](../docs/url-scrubbing.md)) were built ad hoc, but redacting secrets in URLs is a common problem, at least for logging libraries. Look for open source libraries or rule sets that already do it (logging and observability libraries' URL sanitizers, secret scanners' patterns), and compare their parameter names, email and token detection, and test cases with ours. Use: adopt their name lists or tests, or the library itself if one fits Swift.

## Order of work and rough size

1. **Tracker** (in progress): ~1.3–1.9k LOC. Collecting since 2026-11-22. Next: consistency checks (#3), privacy (exclusions), menu bar item, video / call signals. Validate by running alongside Timing and comparing daily totals.
2. **Timing import:** ~200–400 LOC, 1–3 days.
3. **Server + UI:** ~4–8k LOC, ~5–10 weeks. Mostly ordinary UI work.

The tracker is useful on its own: data accumulates in our own format even before the UI exists.
