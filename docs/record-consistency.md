# Record consistency

How the tracker keeps the principle that **every row describes one real moment**: a row's attributes belong together, were all true at once, and hold for its whole span, and rows never overlap. The rule and why it matters: [tracker-principles.md](tracker-principles.md). The sampling mechanisms this doc refers to: [sampling.md](sampling.md).

## Behaviour

- **Attributes that belong together are read together.** Each row comes from one snapshot, read in one pass.
  - The window title, role and document path come from the same window element.
  - The page URL and page title come from the same page element.
- **Changes are recorded only once confirmed** by settling ([sampling.md](sampling.md)), so a row doesn't mix two states.
- **A field is NULL only when the value really isn't there.** Example: when a DevTools window is focused, there's no page URL that belongs to its title. The tracker never fills a field from another window or an earlier sample.
- **Rows never overlap,** even when the clock jumps backwards (see "Watermark").
- **Only one tracker writes a database** (see "One tracker per database").
- **Readers get a consistent view.** The database is in WAL mode, so the server reads committed rows while the tracker writes.

## Separate writes

Closing the open row and inserting the next one are separate autocommit statements, not one transaction. Code: `Recorder`, `IntervalStore`.

- **The close goes first, on its own.** It doesn't depend on the lookup inserts and the row insert for the next state.
- **If the close fails,** the row stays open in memory and the next sample retries it.
- **If the insert fails,** the old row is already closed and there's no open row: the next sample opens one. The time between is a gap.

So a failure leaves a gap, never an overlap or a row that runs on with a stale state.

## Watermark

The *watermark* is the latest `end_ms` of any closed row, read from the database at startup and raised with every close.

- **No row starts before the watermark.**
- **While the clock is behind it** (the clock was set back), the tracker records nothing and logs a warning once. When the clock passes the watermark again, it logs that and records again.
- **A clock that goes backwards under an open row** closes that row at its last sample, and the same rule applies.

So the time spent under the earlier clock is a gap ([data-model.md](data-model.md)). A forward jump also just looks like a gap.

## One tracker per database

At startup the tracker takes an exclusive `flock` on `<db>.lock`, next to the database file, and holds it for its lifetime. Code: `InstanceLock`.

- **A second tracker for the same database exits** (with status 0). Under launchd (`KeepAlive`) it's started again every `ThrottleInterval`, so it takes over if the first one goes away.
- **The kernel releases the lock** when the process exits, even on a crash or `kill -9`, so there's no stale lock to clean up.
- Trackers on different databases (tests, `TIMETRACKER_DB`) don't affect each other ([architecture.md](architecture.md)).

## Known ways to break consistency

| # | Issue | Status |
|---|---|---|
| 1 | **In-between states.** A browser commits the new URL before the new title (or a single-page app the other way round), so a sample in between would record one page's title with another's URL. The same happens mid-switch between apps or tabs. | **Handled** for states shorter than ~400 ms by settling. Longer ones still get rows (Firefox's bare-app-name title, 2–5 s). |
| 2 | **Title and URL from different windows or tabs.** | **Avoided:** both come from the focused window, URL and page title from the same page element. Would matter again with Apple Events, whose `front window` can differ from the focused one. |
| 3 | **Reads that aren't atomic.** App, window and page are read tens to hundreds of ms apart, and the user can switch apps in between. | **Open.** Planned: check the frontmost app again after sampling, and discard and re-sample if it changed. |
| 4 | **Late boundaries.** A change is recorded when it's noticed, up to 5 s after it happened. | **Accepted;** bounded by the poll interval ([sampling.md](sampling.md)). |
| 5 | **Idle rows with attributes from later.** A backdated idle row would carry what was on screen when idle was noticed, not at the last input. | **Handled:** if the first idle sample also shows a change, the old state gets its own idle row up to the change ([idle-and-away.md](idle-and-away.md)). **Open (minor):** backdating reaches only into the open row, so rows closed after the last input stay not idle. |
| 6 | **The clock jumps backwards,** which would make rows overlap. | **Handled** by the watermark. How to show this to the user is open. |
| 7 | **Two trackers** write the same database. | **Handled** by the lock. |
| 8 | **The open row's end on disk lags** by up to 30 s. | **By design.** Readers treat the newest row as possibly ongoing ([data-model.md](data-model.md)). |
| 9 | **No final sample before sleep,** since macOS doesn't wait for apps to handle `willSleep`. | **Handled** by the 20 s gap rule: the first sample after wake ends the row at the last sample before sleep ([sampling.md](sampling.md)). The same holds when a hung app stalls sampling past 20 s. |

## Why

- **A delay over a mismatched row.** Rules attribute time row by row. A mismatched row files time under the wrong project, and nothing downstream can tell. A short delay in writing costs nothing anyone sees.
- **A gap over a guess.** When the tracker can't be sure of a state (a failed write, a clock it can't trust, missed samples), recording nothing is honest; extending or inventing a row isn't.
- **No transaction around close and insert.** In one transaction, a failure in the insert's lookups would roll back the close too, and the old row would keep growing with a state that no longer holds.
- **A lock file, not a check of running processes.** The lock is per database, so test builds and a second copy on another database run freely, and the kernel cleans it up after a crash.
