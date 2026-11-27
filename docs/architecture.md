# Architecture

| Piece | Tech | macOS permissions | Runs |
|---|---|---|---|
| **Tracker** | Swift app | Accessibility | always (LaunchAgent) |
| **Server** | Scala, GraalVM native image | none | always (LaunchAgent), or on demand |
| **UI** | Scala.js | n/a | browser tab (or Safari "Add to Dock") |

## One database, split by owner

- **One SQLite database** in WAL mode: `~/Library/Application Support/com.raquo.timetracker/timetracker.db`. WAL lets the server read a consistent view while the tracker writes.
- **The tracker writes only its own tables** (`tracker_*`: raw activity, see [data-model.md](data-model.md)).
- **The server writes only its own tables:** projects, rules, manual edits, caches, settings. It never writes tracker tables. This is a convention, not enforced by SQLite.
- **Each side runs its own migrations** on its own tables, with its own version table (the tracker's is `tracker_schema`). See [conventions.md](conventions.md).
- **Tables are named by owner and by who decides.** For example, a user's choice is a *choice* in a server table, and the tracker's finding is a *probe result* in a tracker table, never both called "mode".

## Settings that change tracking

Some settings change what the tracker does: per-app page reading today; exclusions and per-site scrubbing exceptions later. They're edited in the UI, so they belong to the server.

- **They live in server-owned tables the tracker only reads.** Example: `app_page_reading_choice`.
- **Edits take effect within one sample, without re-reading the tables on every sample.** SQLite's `PRAGMA data_version` is a counter that changes whenever another connection (here, the server) commits a write to the database. The tracker reads it on each sample, which is cheap, and re-reads its settings tables only when it has changed.
- **A missing settings table means "all defaults".** The tracker can start before the server has ever run, so it doesn't require the server's tables to exist.
- **The column names are a contract.** The tracker queries specific columns of the server's table, so the server's migration must create it with exactly those columns. The tracker's side is in its code (e.g. `PageReadingStore`).

## Isolation

- **Tracker and server are separate signed bundles** with separate bundle IDs. Each is launched by launchd as its own LaunchAgent, never by the other.
- **Why:** macOS grants permissions per signed app and passes them to child processes. Kept apart, the server (a web server, with many libraries) has none of the tracker's Accessibility access. Check: `AXIsProcessTrusted()` in the server returns `false`.
- **Stable signing identity:** the tracker is signed with the same self-signed identity on every build, so its Accessibility permission survives rebuilds. Setup: [tracker/README.md](../tracker/README.md).
- **One tracker per database:** a second tracker started on the same database file exits right away (an exclusive `flock` on `<db>.lock`), and launchd retries it. The lock is per file, so trackers on other databases run alongside: the test suite gives each test its own temporary database, and a manual test run can point a tracker at its own file (`TIMETRACKER_DB`).

## Record raw facts, categorize later

- **The tracker knows nothing about projects or rules.** It records what was on screen.
- **The server owns all interpretation:** attribution to projects, normalization of titles, derived fields (domains, app-specific context), rollups. All of it is computed from the raw tables.
- **Why:** rule and normalization changes apply to all history, and a mistake in interpretation can be fixed after the fact. A mistake in what the tracker records can't, which is why the tracker records generously ([tracker-principles.md](tracker-principles.md)).

## Priorities differ by piece

- **The tracker optimizes for being lightweight,** since it runs all day ([tracker-principles.md](tracker-principles.md)).
- **The server and UI optimize for ease of development.** They run only while used.

## Server security

- It's served on `127.0.0.1` only.
- It checks the `Host` header and requires a token, so other local programs and websites (through DNS rebinding or requests from the browser) can't use the API.

## Code

Tracker code layout: [tracker/README.md](../tracker/README.md), "Code layout".

## Operating environment

- **macOS 15 or later.**
- **No App Nap:** the tracker opts out (`Tracker.start()`), so its timers (the poll, settling, event delays) fire on time. It doesn't keep the Mac or the display awake.
