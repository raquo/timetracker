# Tracker principles

Rules every tracker feature follows. Other docs refer to them instead of restating them. When a new feature seems to need an exception, it's a decision to make on purpose, recorded here.

## No keylogging, ever

**Rule.** The tracker never records keystrokes or typed text, and never installs a keyboard monitor or event tap, not even as a sampling trigger. Input is used only as "time since the last input" (for idle) and "a click happened" (as a trigger to sample), never where or on what.

**In practice.**
- Idle comes from macOS's idle timer (`CGEventSource.secondsSinceLastEventType`), which reports only how long ago the last input was.
- Clicks are a sampling trigger with no position or target.
- Signals are about *what was on screen*, never *what the user typed*. Reading a page's URL and title is in; reading a text field's contents is out.

**Why.** A tracker with Accessibility access could read almost anything. Trusting it to run all day depends on a hard line that's easy to check, and this is that line.

## Record raw data generously

**Rule.** While the tracker is young, record any cheap raw signal that might help explain or attribute time later, in as much detail as it comes. When unsure whether something is noise or useful, record it.

**In practice.**
- The tracker drops data only when it's certainly empty, or for privacy:
  - empty: an `about:blank` placeholder, an app's own UI loaded from inside its bundle;
  - privacy: URL scrubbing, and exclusions once they exist.
- Everything else is the server's to filter. For example, browsers' own pages (`chrome://new-tab-page/`, `about:newtab`) and app-private schemes (`app://obsidian.md/…`) count as content and are recorded.
- Each new signal is still weighed against its cost: the tracker's CPU, and row churn. A signal that changes constantly (a window's frame while it's dragged) multiplies rows.
- Not yet recorded: power assertions, camera and mic (the columns exist, NULL for now).

**Why.** The server can ignore or reinterpret what it doesn't use, and rules apply to all history. Unrecorded history can't be recovered.

## Privacy is enforced in the tracker, before writing

**Rule.** Anything that must not be stored is removed before it reaches the database: URL scrubbing today, exclusions later.

**In practice.**
- URLs lose their fragment, and secret or personal values are replaced with `REDACTED`, before the lookup insert. This covers page URLs and web URLs reported as the window's document (`AXDocument`).
- Settings that change what's tracked (exclusions, per-site scrubbing exceptions) will live in server tables that the tracker reads (see [architecture.md](architecture.md)), and are applied at sample time.

**Why.** A later cleanup can't un-write the file. Deleted rows can linger in the WAL file, free pages and backups.

## Lightweight

**Rule.** The tracker runs all day and must not be noticeable.

**In practice.**
- It samples on events (app activation, Accessibility notifications, clicks), with a 5 s poll as a backstop. It doesn't poll fast.
- Each sample makes a few cheap calls. Every Accessibility call times out after 0.5 s, so a hung app can't stall the tracker.
- It flushes the open row's end to disk every 30 s, not on every sample.
- Costlier reads, like searching a window for its web page, are done only in apps where they pay off (page reading's per-app mode).

**Why.** Background trackers that cost noticeable CPU or battery get switched off. The server and UI, which run only when used, optimize for ease of development instead.

## Every row describes one real moment

**Rule.** A row's attributes belong together, were all true at once, and hold for its whole span. Rows never overlap. When the state is in flux, prefer a short delay over a mismatched or incomplete row.

Rules attribute time per row, so a mismatched row (one tab's title next to another tab's URL) is time silently filed under the wrong project, and nothing downstream can detect or repair it.

The details (settling, separate writes, the clock watermark, the known ways this can break) are in the consistency notes in [PLAN.md](../notes/PLAN.md), until they get a topic doc.
