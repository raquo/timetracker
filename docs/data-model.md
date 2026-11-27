# Data model (tracker tables)

What the tracker's tables mean, for anyone reading them: the server, ad hoc queries, debugging. The columns and their comments are in [Schema.swift](../tracker/Sources/TrackerCore/Storage/Schema.swift), which is the source of truth for the exact DDL. This doc explains how to interpret the data. Example query: [Look at the data](../tracker/README.md#look-at-the-data) in tracker/README.md.

All tables are prefixed `tracker_`, and only the tracker writes them (see [architecture.md](architecture.md)).

## App identity

**An app identity is the pair `(identifier_type, identifier)`:** the app as the user thinks of it, wherever it's installed. In code: `AppIdentity`.

- `identifier_type` 0: `identifier` is the bundle ID.
- `identifier_type` 1: `identifier` is the full executable path, for processes without a bundle ID. Never a bare process name.

Moving or updating `Foo.app` keeps the same app identity. Tables keyed by app identity: `tracker_app_page_probe`, and the server's `app_page_reading_choice`. `tracker_app` has one row per app identity *and* install path.

## Intervals: `tracker_interval`

**One row per stretch of time with identical attributes.** The tracker samples what's on screen; consecutive equal samples extend the open row, and a changed sample closes it and opens a new one.

- **Span:** `[start_ms, end_ms)`, Unix epoch milliseconds. Rows never overlap.
- **Gaps** between rows mean no data. A gap isn't "away"; idle and lock are rows of their own. Causes:
  - the Mac was asleep;
  - the tracker wasn't running;
  - **the system clock was set back.** When the clock jumps backwards (set by hand, or corrected by network time – not because related to DST offset changes), new samples would get times that overlap rows already recorded. Instead, the tracker records nothing until the clock passes the latest recorded `end_ms` again. So the time spent under the earlier clock is a gap, and no rows overlap ([record-consistency.md](record-consistency.md)). A forward jump just looks like a gap.
- **The newest row may still be ongoing.** The tracker writes its `end_ms` every 30 s, so on disk it lags by up to 30 s. Readers should treat a row that ended within the last 30 s as possibly still open.

Attributes, all describing the frontmost app's focused window at that moment:

| Column | Meaning |
|---|---|
| `app_id` | The frontmost app → `tracker_app`. NULL while the screen is locked. |
| `title_id` | Window title (`AXTitle`) → `tracker_title`. |
| `window_role_id` | Role and subrole of the focused window → `tracker_window_role`. Tells normal windows from panels, dialogs and Picture-in-Picture windows. |
| `is_main_window` | Whether the focused window is also the app's main window. A focused panel or popup usually isn't. |
| `is_full_screen` | Whether the focused window is in full screen. |
| `document_path_id` | The window's document (`AXDocument`) → `tracker_path`. A plain file path for `file://` documents; a scrubbed URL when the app reports a web address (Chrome reports the tab's URL). |
| `page_url_id`, `page_title_id` | URL and title of the same web page: the one shown in the focused window, in apps whose pages are read (browsers, Claude, …) → `tracker_url`, `tracker_title`. Both are read from the same page element. URLs are scrubbed. |
| `is_input_idle` | 1 inside a stretch of ≥ 60 s without user input (keyboard, mouse, trackpad). The stretch starts at the last input: [idle-and-away.md](idle-and-away.md). |
| `is_screen_locked` | 1 while the screen is locked. All window attributes are NULL then. |
| `display_sleep_holders` | Which processes hold off display sleep (a video, a call, a keep-awake tool), and why: JSON, see [Presence signals](#presence-signals). |
| `is_camera_in_use` | Some camera is running, in any process. |
| `mic_holders` | Which processes have input running from an audio device (a mic): JSON. |

**NULL means "not known", not "no".** A NULL attribute means the value wasn't there or couldn't be read: no focused window, no Accessibility permission, an app that doesn't report it, or page reading off for that app. It's never a stand-in for an empty or false value. The presence signals are NULL while the screen is locked, and when a read fails.

**Older rows lack newer columns.** Columns added by later migrations (window role, main window, page title, presence signals) are NULL in rows recorded before them.

**Input-idle stretches have their real length,** so the server can apply any away threshold of 60 s or more: [idle-and-away.md](idle-and-away.md).

### Presence signals

What they are for, and where they come from: [idle-and-away.md](idle-and-away.md#presence-signals). `display_sleep_holders` and `mic_holders` are JSON arrays of objects, one per holder:

```json
[{"app":7,"rsn":"caffeinate command-line tool","via":31},{"app":12,"rsn":"Video Wake Lock"},{"app":40,"rsn":"Amphetamine (Single-Use - Display)"}]
```

| Key | Meaning |
|---|---|
| `app` | The process the signal is for → `tracker_app.id`. Left out when it couldn't be identified (the process exited before the tracker looked it up). |
| `rsn` | The power assertion's name, as the app gave it. Display sleep only. |
| `via` | The process holding it on `app`'s behalf (caffeinate) → `tracker_app.id`. Only when there is one; display sleep only. |

- **`[]`:** measured, and nothing holds it. **NULL:** not measured.
- **When they're read** (also `is_camera_in_use`): [idle-and-away.md](idle-and-away.md#presence-signals).
- **Canonical form:** sorted by `app`, then `rsn` (byte for byte), then `via`, absent values first; no duplicates; keys in that order. Equal sets give equal strings, so a row only splits when the set changes, and the strings can be compared directly.
- **Held or in use:** `x <> '[]'` (false for NULL too). Not: `x = '[]'`. Not measured: `x IS NULL`.

## Apps: `tracker_app`

**One row per app identity per install location.** The same app at two paths is two rows, so history keeps which copy ran. Referenced by `tracker_interval.app_id` (the frontmost app) and by the holders of [presence signals](#presence-signals), which include daemons and command-line tools (`/usr/bin/caffeinate`, identifier type 1).

| Column | Meaning |
|---|---|
| `identifier_type`, `identifier` | The app identity (above). |
| `app_path` | The `.app` bundle's path, or the executable's path when there's no bundle. `''` if macOS didn't say. |
| `name` | The localized display name, as last seen. Updated in place when it changes, so it's not historical. |

**Caveat: generic runtimes.** Some identifiers cover unrelated apps: `org.python.python` for any Python GUI script, `com.github.Electron` for any Electron app run from source. Rows are already per path, so the server can later map them to separate logical apps without touching tracker tables.

## Lookup tables

Repeated strings are stored once and referenced by ID:

- `tracker_title`: window titles and page titles, shared.
- `tracker_path`: document paths.
- `tracker_url`: page URLs.
- `tracker_window_role`: (role, subrole) pairs, as the app reports them. `''` when not reported. A table rather than an enum because the values aren't a closed set: besides Apple's standard ones (`AXStandardWindow`, `AXDialog`, `AXFloatingWindow`, …), apps report their own (a Quick Look window has the subrole "Quick Look", and some windows report a role other than `AXWindow`).

Rows are only ever added, never removed, even when no interval uses them any more. A lookup row says nothing about when it was seen; join from intervals for that.

**Strings are stored byte for byte, as macOS reported them.** Unicode normalization is kept: "é" precomposed and "e" + combining accent (common in file names) are two different rows. So is a title containing a NUL.

Two consequences for readers:
- **Compare titles normalized (NFC) when grouping.** Otherwise the same title can show up as two.
- **A title that only switches normalization form doesn't start a new interval.** The tracker compares samples with Swift's `==`, which treats the two forms as equal, so the row keeps the form seen when it opened.

## Page probe results: `tracker_app_page_probe`

**One row per app identity, from the app's first probe on:** what the tracker found out about whether the app shows web content pages, and so whether reading its pages is worth it.

| Column | Meaning |
|---|---|
| `identifier_type`, `identifier` | The app identity (above). Primary key. |
| `has_content_pages` | The probe result. 1: a probe saw a content page, so page reading is on. 0: none seen in 30 min of active use, so it's off. NULL: still probing. |
| `decided_at_ms` | When `has_content_pages` was decided. NULL exactly when it is. A re-probe requested after this time starts probing again. |
| `probe_count` | Probes so far. For debugging. |
| `first_probe_at_ms`, `last_probe_at_ms` | When the first and the latest probe ran. For debugging. |

The probe counts and times are saved on the first probe, on a decision, and when the tracker quits or the Mac sleeps, not on every probe. So after a crash they can be behind, but the decision isn't.

The user's choice, which overrides the probe result, is in the server-owned table `app_page_reading_choice`. How probing works: [page-reading.md](page-reading.md).

## Schema version: `tracker_schema`

A single row with the tracker's migration version. The tracker doesn't use `PRAGMA user_version`, because the server shares the database and versions its own tables separately. Migration policy: [conventions.md](conventions.md).

## Why

- **Intervals rather than samples.** A row per sample (every few seconds, all day) would be large and mostly repetition. Intervals keep the data proportional to how often things change, and are what reports sum anyway.
- **Raw facts only.** No projects, categories or rules in tracker tables. Categorizing later means rule edits apply to all history. See [architecture.md](architecture.md).
- **Lookup tables.** Titles and URLs repeat constantly, so each is stored once.
- **Per-path app rows.** History keeps which copy ran, and generic runtimes can be split apart later without rewriting tracker tables.
- **Byte-for-byte strings.** The lookup cache used to compare with Swift's `==`, so a title could be filed under the other normalization form's row depending on what had been looked up since the last restart, and a NUL cut strings short (fixed 2026-11-23). Storing exactly what macOS reported is the only behaviour that doesn't depend on history. Normalizing is the server's job, where it can change.
- **Column names say what they refer to.** `document_path_id` (not `path_id`), `page_url_id` next to `page_title_id` (both from the same page), and `is_input_idle` (no user input, not an idle CPU or app). Renamed in migration 6.
