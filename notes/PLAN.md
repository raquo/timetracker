# Time Tracker — plan

Progress, open questions and ideas. What the app does and why, as built: [docs/](../docs/README.md). Research notes, until they move into docs: [tracking-techniques.md](tracking-techniques.md), [electron-and-claude.md](electron-and-claude.md). Tracker build, install and data queries: [tracker/README.md](../tracker/README.md).

## Status

**Tracker:** running daily as a LaunchAgent since 2026-11-22, writing to the real database (schema version 5). Data was reset on 2026-11-22 at 20:58 (migration 1 edited in place: `identifier_type` became an integer; policy: [docs/conventions.md](../docs/conventions.md)). Records app, window title and kind, document path, page URL and title in apps where probing found content pages (browsers, Claude, …), idle, screen lock and sleep gaps. Not yet: video / call / camera / mic signals, menu bar item, exclusions.

**Server, UI, Timing import:** not started.

### Done so far

- Swift package in `tracker/`, signed with a stable self-signed identity ("Time Tracker"), installed to `~/Applications/TimeTracker.app`, run by launchd (`com.raquo.timetracker.tracker`). Accessibility permission granted and survives rebuilds.
- Schema with migrations (`tracker_schema` version table, so the server can migrate its own tables independently): intervals, lookup tables for apps / titles / paths / URLs / window roles.
- Sampling: app activation and Accessibility events (focused window, window title; for apps whose pages are read also focused element, page title, page load), any click (600 ms later), and a 5 s poll.
- Page URL and title through the web Accessibility tree. Verified on Claude Code sessions and regular chats, Firefox, Safari and Chrome. Since 2026-11-23 adaptive (below): no allowlist, every app is probed.
- Idle: ≥ 60 s without input, backdated to the last input.
- Consistency safeguards: separate writes for close / open, no overlapping rows on backward clock jumps (watermark), single instance per database (`flock`), final sample before quit / sleep.
- `--dump-ax` diagnostic mode to explore what an app exposes, and to measure the tracker's page search in it.
- Browser URLs (2026-11-22): Firefox, Safari and Chrome expose the shown tab's page in the Accessibility tree without any switch, so they go through the same reader as Claude; no Apple Events, no Automation prompts. URL scrubbing (fragment dropped, Gmail keeps its view; credentials and secret-looking parameter values redacted). Settling before recording.
- Adaptive page reading (2026-11-23): every app is probed (one window search on window change and once a minute); a content page seen → on, none in 30 min of active use → off; the user's choice in a server table overrides. Replaced the allowlist and its `accessibilityTreeApps` defaults key.
- Code review pass (2026-11-22): one global 0.5 s Accessibility timeout; shared Accessibility helpers and lookup tables; no page cache (each sample searches afresh, so it never reports a page no longer shown); web content pages told apart from the app's own UI by "loaded from the app's bundle", not by scheme; Claude-specific code in `Apps/Claude.swift`.

## Tracker (Swift)

Principles (no keylogging, record generously, privacy before writing, lightweight): [docs/tracker-principles.md](../docs/tracker-principles.md).

### What it records

Tables and what they mean: [docs/data-model.md](../docs/data-model.md). Not moved yet:

**URL scrubbing (decided and done 2026-11-22, redaction 2026-11-23, `UrlScrubber.swift`):** before recording, every URL loses its fragment (see "URL fragments"), and secrets and personal data are **redacted**: the value is replaced with `REDACTED` and the name kept (`?token=REDACTED`, `https://REDACTED:REDACTED@host/`), as logging tools do (Rails' `[FILTERED]`, OpenTelemetry's `REDACTED` for signed-URL parameters and user info). So the URL keeps its shape and still says a secret was there (a sign-in or password reset link), in line with "record raw data generously". Empty values stay (nothing to hide). Redacted: any `user:password@`, the values of path parameters under the same names (`;jsessionid=…`) and of parameters after a `;` in a query value (`?a=1;token=…`, as some servers split on `;`), and of query parameters whose name says they hold a secret (names matched in any spelling: case, `snake_case`, `kebab-case`, `camelCase`, run together; for form fields like `user[login]` the innermost key also counts; see `LooseNamePattern`) (`code`, `key`, `sig`, names containing `token`, `secret`, `password`, `signature`, `session`, `sessid`, `api_key`, `access_key`, `X-Amz-*`, …) or personal data (`login`, `username`, names containing `email`), and values that contain an email address (also within a search query, or encoded twice). One-time codes under other names (`oobCode`, `auth_code`, `verification_code`, …), `oauth_verifier` and card codes too; harmless codes (`country_code`, `promo_code`) stay. A URL carried in a parameter (`?next=`, `?continue=`, `?redirect_uri=`) is scrubbed by the same rules, up to 3 levels deep, and re-encoded; left byte for byte if nothing in it changes; redacted whole if an email address is left in its path. A `data:` URL (an image or a page opened from one) keeps only its media type: `data:image/png;base64,REDACTED`. Open: an email address in the path (`/u/alice@example.com`) is kept, and so are secrets inside structured values (`?state=` holding JSON or base64 with a token). Other parameters stay (`?v=`, `?q=`, GitHub's `?state=closed`, tracking parameters like `utm_*`). Document IDs in the path stay too: shared documents (Google Docs) have their own access control. Redacted values can't be recovered later. The same scrubbing applies to URLs apps report as the window's document (`AXDocument`; Chrome gives the tab's URL), which are stored in `tracker_path`. Rules and cases: `UrlScrubber.swift`, `UrlScrubberTests.swift`.

**URL fragments:** the tracker drops the `#…` part of every URL before recording it. Fragments are usually a position within the page (Notion's `#<block-id>`, heading anchors), which splits rows with no information about what's being worked on, and they can carry secrets (`#access_token=…`). Applies to all URLs, including browser URLs once we record them. Exception: apps that route by fragment keep its first segment, if it's a plain word: Gmail `#inbox/<message-id>` → `#inbox` (the message is in the title). List: `UrlScrubber.fragmentRoutedHosts`, so far only `mail.google.com`. Dropped fragments can't be recovered later.

**Idle:** `is_input_idle = 1` inside a stretch of ≥ 60 s without input, starting at the last input ("backdated"). Never back into a locked-screen row: after an unlock without input (Apple Watch), the screen counts as locked until the unlock, then idle. So the server can apply any away threshold ≥ 60 s to all history: a run of consecutive idle rows is one input-free stretch. **Away rule (first version, server):** no input for N minutes counts as away, unless a display-sleep assertion is held or the camera / mic is in use (videos, calls, presentations).

### Record consistency

Principle: every row describes one real moment ([docs/tracker-principles.md](../docs/tracker-principles.md)). How:

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
| 5 | **Backdated idle rows carry later attributes**: their app / title would be from when idle was detected, not from the last input. | Handled (2026-11-23): if the first idle sample also shows a change, the old state gets an idle row from the last input until the change was first seen. Open (minor): idle backdating reaches only into the open row, so rows closed after the last input (a title change while away) stay not idle. |
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
- **Finder folder** via Apple Events (`target of front window`): Finder leaves `AXDocument` empty.
- **More raw signals** (candidates): role of the focused UI element (text field vs web area), window frame / which display, number of displays, the window's `AXIdentifier`, the app's window count, audio output playing, Focus mode. Beware of signals that change constantly (window frame while dragging) and multiply rows.
- **Fast user switching:** while another macOS user is active, the tracker keeps sampling, and that time is recorded as idle in whatever app was frontmost. Handle `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` like lock / unlock (or as a gap).
- **Generic runtimes, going forward:** if we decide to identify some apps by path (see Server), the tracker could write a new `identifier_type` for a known list; needs a migration to widen the `CHECK` constraint (in SQLite: rebuild the table).

### Tracker: consistency and noise

- **Mismatched samples** (consistency #3 and others): when a double-check fails and the sample is discarded, decide what the discarded span is attributed to: extend the previous row (last known-good state), leave a gap, or record only the fields we're sure of (e.g. app without title / URL). Cap retries.
- **Brief noise rows:** sub-second artifacts, not activity: the first sample after switching on an app's Accessibility tree (built lazily, so no URL yet), in-between states while switching. (Zero-length rows opened by the closing sample on quit / sleep are already deleted.) Avoid writing them where we can tell (e.g. wait for a new tree to be ready), and filter the rest in the server (merge into a neighbour below some duration). Settling drops those shorter than ~400 ms.
- **Retry missed Accessibility subscriptions** (`WindowObserver`): if adding a notification fails (e.g. an app that has only just launched and isn't answering Accessibility yet), it isn't retried while that app stays frontmost, so its window and title changes are caught only by the 5 s poll until the user switches away and back. Check `AXObserverAddNotification`'s result and retry on the next sample (for the focused window's title subscription too).
- **A sleep that never wakes the tracker:** after `willSleep` the tracker records nothing until `didWake`. If macOS ever posts the first without the second (a sleep that's cancelled or fails), recording stops silently until the next sleep. Not seen; unknown whether it can happen. Safety net if it does: treat a click or an app activation while "asleep" as a wake (the user is clearly there; dark wakes for Power Nap have neither), and log it.
- **Check: does a Touch ID unlock count as input?** Lock the screen, wait over a minute without touching anything, unlock with Touch ID, then look at the row after the unlock. Idle means macOS's idle timer (`CGEventSource.secondsSinceLastEventType`) doesn't count Touch ID, so such unlocks take the "unlock without input" path (handled since 2026-11-23: the locked row stays locked, the idle row starts at the unlock). Either way, note the answer here.
- **Clock jump UX:** today the tracker pauses silently (with a log line) while the clock is behind recorded data. Decide how to surface it: a menu bar warning, an offer to pause tracking (e.g. a developer testing time-related code), or discarding rows recorded under the wrong clock. Forward jumps currently just look like a gap.

### Tracker: privacy

- **Sensitive data in URLs and titles:** URL values are redacted by a denylist of parameter names (see "URL scrubbing"). Open: secrets in parameters with innocent names, or in the path (magic sign-in links like `/login/<token>`); titles carrying email subjects, document names, chat snippets. Research how other trackers handle it: Timing, RescueTime, Rize, ActivityWatch's browser extensions, Toggl Track's autotracker, Apple Screen Time.
- **Google Calendar event IDs (decided 2026-11-23: keep):** `?eid=…` and `/eventedit/<id>` are base64 of the event ID plus the calendar owner's email address. Kept: not a secret, not readable at a glance, and the event ID says which meeting the time went to. Revisit if recorded data is ever shared or exported, or if `isEmailAddress` should learn to look inside base64.
- **Per-site exceptions to URL scrubbing:** let chosen parameters through for a domain or URL pattern where the denylist redacts something useful (e.g. a `key` or `code` parameter that names a document or a view, not a secret). Like exclusions, a server table the tracker reads.
- **Web addresses in `AXDocument` (scrubbed since 2026-11-23):** Chrome reports the tab's URL (`https://…`, `chrome://…`) as the window's document, so it was stored unscrubbed in `document_path_id` (then `path_id`) next to the scrubbed `page_url_id`. Now non-file URLs there go through `UrlScrubber` too (not recorded if they can't be). Rows recorded before still hold the raw URLs (8 paths on the dev Mac); clean up by hand if wanted. Still worth a look: which other apps report a non-file `AXDocument` (`SELECT DISTINCT path FROM tracker_path WHERE path NOT LIKE '/%'`).
- **Strip tracking parameters:** `utm_*`, `fbclid`, `gclid`, `mc_eid`, `ref_src` and the like say nothing about what's being worked on but split one page into several URLs. Consider removing them in `UrlScrubber` (they're kept today).
- **Exclusions:** skip tracking for chosen apps, domains (incl. subdomains), title patterns, and private / incognito browser windows; plus pause. Decide per rule whether excluded time is recorded as a bare "excluded" row (time counted, no detail) or as a gap. Enforced in the tracker, so it needs to read a small exclusion config.
- **Deleting tracked data, and cleaning up lookup rows:** once users can delete recorded time (e.g. for privacy), lookup rows (`tracker_title`, `tracker_url`, `tracker_path`, `tracker_window_role`, maybe `tracker_app`) that no remaining interval uses should be deleted too, or the secret title or URL stays in the database. Also decide who deletes: only the tracker writes tracker tables (docs/architecture.md), so either the server asks through a table the tracker reads (like settings), or deletion becomes a documented exception. Afterwards `VACUUM` (or `secure_delete`), since deleted data lingers in free pages and the WAL.

### Tracker: cost

- **Measure and document the tracker's system load,** as a whole and per source: how often it calls which APIs (Accessibility reads per sample, page searches, observers, idle and lock checks) and what each costs; how often and how much it writes to disk (inserts, the 30 s end-of-row flush, lookup inserts, WAL growth and checkpoints, probe saves); its CPU, memory and energy impact over a normal day (Activity Monitor's Energy tab, `powermetrics`, `fs_usage` for writes). Write the result into docs as the tracker's cost budget, and re-measure after changes to sampling. The Electron tree's cost to other apps is a separate item ("Measure its cost" below).

### Tracker: Accessibility tree in other apps

- **Adaptive page reading (implemented 2026-11-23, replaced the allowlist; `PageReadingPolicy.swift`).** Instead of a fixed list of apps whose page URL and title we read, every app starts in "auto" and the tracker finds out by itself whether reading pages is worth it there.
  - **Scope:** only the page part (web areas: page URL and title, the switch, the extra observers). Window title, kind and document path stay read for every app, always.
  - **Per-app mode:** auto, on, off. On: search every sample, observers for focus / page title / page load (what allowlisted apps got before). Off: no page reading. Auto: probing, below.
  - **Probing (auto):** one search of the focused window when it isn't the window last probed in that app, and about once a minute, not every sample (kept per app, so switching back to an app doesn't search its window again); no extra observers; rows are recorded without page URL / title meanwhile. Electron apps (detected by `Contents/Frameworks/Electron Framework.framework` in the bundle, so no list) get `AXManualAccessibility` first, since they show nothing without it; every other app is searched without any switch (browsers and native apps with web views expose their pages anyway).
  - **Verdict, from what the probes saw** (content pages: every page except the app's own UI loaded from its bundle, and `about:blank`):
    - On: any content page seen (one URL is enough). Deliberately generous: we don't yet know what document-based apps (LibreOffice, Fusion 360, …) expose, so rather over-sample than miss long-lived documents.
    - Off: no content page seen within the evidence threshold.
    - Refine later (TODO below): apps whose only page is constant and says nothing get "on" for nothing: Obsidian (`app://obsidian.md/index.html` for every note, page title = window title), Zoom (`https://new-home-page.localhost/index.html`, its own UI served over https, seen 2026-11-23). Zoom shows that a rule on the URL's scheme or host can't tell such pages apart (tried and reverted 2026-11-23: only `http(s)` and outside `file://` counting would have caught Obsidian, not Zoom); refine on what the pages do instead. Possible refinements: require ≥ 2 distinct URLs or a page title that differs from the window title; keep a browser left on one "What's new" page in auto instead of deciding off. Related: browsers' own pages count as content and are recorded (Chrome `chrome://new-tab-page/`, `chrome://accessibility/`; Firefox `about:newtab`, and its dialogs, e.g. `chrome://mozapps/content/handling/permissionDialog.xhtml` with the URL as page title). Harmless for the verdict (browsers have real pages anyway), and recorded on purpose ("record raw data generously"); the server may want to treat them as "no page".
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
    - A re-probe request timestamped in the future (the clock went back after the request) keeps the app probing until the clock passes it: every decision is older than the request, and each one re-probes on the next sample. Bounded by the clock difference; not handled.
    - An app briefly showing a web page (a sign-in window, a "What's new" panel) flips to on for good; the user can set it off in the UI. A probe result of off lasts until re-probed, though app updates can add web views. Optional: re-probe when the app's path changes.
    - Probing reads pages in apps that so far only had window titles recorded (password managers, banking apps, Mail): scrubbing applies, but exclusions become more pressing.
  - **Later:** seed known browsers (`Apps/Browsers.swift`) and Claude to on, so they skip the probe. Refine the "on" condition (Obsidian, Zoom, above) once we have probe results from real apps.
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
