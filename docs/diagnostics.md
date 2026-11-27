# Diagnostics

How we find out what an app exposes to the tracker, and how what we find becomes a test. Most of what the tracker knows about apps (where Chrome keeps its page, that Claude's ⌘-click windows report `about:blank`) was learned this way. Three pieces: the dump tool, which reads a running app; Accessibility fixtures, which save one of its windows; and replay tests, which run the tracker's code on saved windows. What the tracker does with an app's tree: [page-reading.md](page-reading.md).

## Behaviour

- `TimeTracker --dump-ax <bundle-id> <output-file>` writes what a running app's windows expose, and what the tracker's page search finds in them, to a text file.
- With `--json` at the end, it saves the app's focused window as a fixture instead: a JSON file, written to the output file given. Fixtures belong in `tracker/Tests/TrackerCoreTests/Fixtures/ax/`.
- `swift test` replays every fixture and checks what the tracker would record from it.
- `TimeTracker --watch-ax <bundle-id or pid> <output-file> <seconds>` logs which Accessibility notifications a running app sends, and when its focused page changes, to a text file as they happen.

How to run the dump tool: [tracker/README.md](../tracker/README.md#page-url-and-title-from-app-web-content).

## The dump tool

**A mode of the tracker's own executable,** not a separate program, so it has the tracker's Accessibility permission and runs the tracker's search code. It must run through `open`, as the installed app (`open -n -W ~/Applications/TimeTracker.app --args --dump-ax …`) or the build copy (same signature, so the same permission): run from a terminal it would get the terminal's permissions instead. It doesn't open the database, so it can run while the tracker records. With the wrong arguments it prints the usage and exits with 2, rather than starting to track. Code: `TrackerMain.command`, `AxDump`.

**First it switches the app's web tree on** (`AXManualAccessibility`, [page-reading.md](page-reading.md#the-electron-tree-switch)) and waits 2 s, since Electron builds the tree lazily. Like the tracker, it leaves the tree on.

**The text output**, in order:

1. Whether the tool has Accessibility permission (`AXIsProcessTrusted`), and the result of switching the tree on.
2. **The page search on every window** of the app, focused window first: elements visited, time taken, and each web area found with its URL and title. These are the tracker's own numbers (the cost table in [page-reading.md](page-reading.md#cost) comes from here).
3. **The focused window:** its attribute names and `AXDocument`.
4. **The focused window's whole tree,** one element per line, indented by depth: role, subrole, title, description, value, DOM id, URL. Web areas also list every attribute they have, since one might hold what the URL doesn't. Values are cut at 80 characters, newlines shown as `⏎`; the walk stops at depth 60 or 8,000 elements.

Errors (no running app with that bundle ID, no focused window) are written to the same file.

## The watch tool

**Finds out which events the tracker could listen for** in an app: which Accessibility notifications it sends when something changes, and for which elements. Run like the dump tool (`open -n -W … --args --watch-ax <bundle-id> /tmp/watch.txt 20`), and make the changes while it runs. Code: `AxWatch`.

- **Each notification is registered three times:** on the app element, on the focused window, and on the focused window's web area (moved along when either changes). Each line says which one it came through, since an app needn't deliver a notification to every registration. Notifications the app element refuses are logged at the start.
- **The focused page is polled every 100 ms,** and a line is written when its URL or title changes, or it's a new element. That shows a change the app sent no notification for, and when a navigation replaces the page element (notifications registered on the old one stop).
- **A pid instead of the bundle ID** picks one copy of an app that runs more than once, such as a second Chrome or Firefox with its own profile (`--user-data-dir`, `-profile`), beside the user's.
- Lines are in ms since the start; the first line gives the start in Unix ms, to line up with another log. Titles and URLs are written as they are, unscrubbed: the file is for a look on this machine.

Found with it: WebKit sends nothing for a page title change or a URL change without a load; Chrome sends nothing for a URL change without a load or a new title ([page-reading.md](page-reading.md#background)).

## Accessibility fixtures

**A fixture saves one window of an app for tests:** the focused window's tree, trimmed to what the tracker reads, plus what the tracker's page search found on it live. Written by `--dump-ax … --json`. Code: `AxFixture`.

A fixture holds only these:

- every element: role and subrole;
- the window: title, `AXDocument`, main, full screen;
- web areas: URL (as reported, not scrubbed), title, description;
- the path from the window down to the element holding keyboard focus (`focusPath`), since the page search walks up from it;
- the live result: elements visited, the content pages found, and which one was chosen.

**Trimmed where the page search stops:** the contents of web areas and toolbars aren't recorded, except the branch down to the focused element. Past 2,000 elements or depth 60 nothing more is recorded. Trimmed elements are marked (`isTrimmed`).

**Names:** `<app>-<what's shown>.json`, such as `chrome-example-page.json` or `claude-cmd-click-window.json`.

**Fixtures are committed, so they should be recorded on neutral pages** (example.com, a test chat called "Greeting") and read before they're added. Labels, values and page text are never recorded, but window titles, page titles and URLs are, unscrubbed. The fixtures' own README says the same: [Fixtures/README.md](../tracker/Tests/TrackerCoreTests/Fixtures/README.md).

## Replay tests

`AxReplayTests` rebuilds each fixture from fake elements (`FakeNode`) and checks two things:

1. **The replay finds what the live search found:** the same elements visited, pages and choice. This shows the fakes behave like the real elements, so the second check means something.
2. **The tracker records the expected snapshot:** the window's attributes, document path and chosen page, read by `Sampler`'s own code (`readFocusedWindow`, `findPage`). The expected snapshot for each fixture is written by hand in `AxReplayTests.expected`; a new fixture without one fails until it's added, and so does an expectation whose fixture is gone, or no fixtures at all (a moved folder would otherwise leave nothing to check).

Known gaps are pinned the same way: `claude-cmd-click-window` expects only the window title, so a fix shows up as a test to update.

`AxFixtureCaptureTests` checks the recording itself on hand-built trees: that page text, labels and the toolbar's contents aren't saved, that the focus path survives, and that huge trees are cut.

## Checking a new app

Before relying on what the tracker records from an app (or deciding to switch page reading off for it), look at what it exposes. This is a manual check, not the tracker's automatic probing ([page-reading.md](page-reading.md#page-reading-mode)), though it uses the same search.

1. **Set the app up as it's normally used:** a real document or page open, focus where it usually is. For Electron apps, expect the tree switch to stay on afterwards; VS Code will show its screen reader prompt.
2. **Dump it as text** and read the page search lines: did it find a web area, with which URL and title, after visiting how many elements, in how many milliseconds?
3. **Change what's shown** (another note, chat, tab) and dump again. A URL or title that doesn't change says nothing (Obsidian's `app://obsidian.md/index.html` for every note).
4. **Look at the window too:** its title and `AXDocument`. Some apps give more there than in any page (VS Code's file path).
5. **Try the odd windows:** pop-outs, players, sign-in windows, split views. This is where gaps show up (Claude's ⌘-click windows, Firefox's Picture-in-Picture).
6. **Save what matters as a fixture** with `--json`, on a neutral page; read the file; write its expected snapshot in `AxReplayTests`.
7. **Write down what you found** in the research notes, with the date and the app's version: [tracking-techniques.md](../notes/tracking-techniques.md), [electron-and-claude.md](../notes/electron-and-claude.md). If the app needs a decision (page reading off, app-specific code in `Apps/`), make it on purpose.

## Why

- **Inside the tracker's executable.** Accessibility permission is tied to the signed app, so a separate tool would need its own grant. And it runs the real search, so its numbers are the tracker's.
- **Output to a file, not the terminal.** It runs through `open` as an app, whose output doesn't reach the terminal that started it.
- **Fixtures save only what the tracker reads.** Page content can hold anything, and fixtures are committed; it also keeps the files small.
- **Fixtures carry the live search result,** so a replay can be checked against the real app, not only against expectations written afterwards.
- **Expected snapshots written by hand,** not generated from the current code: a generated one would accept whatever the code does today, bugs included.

## Limitations

- **A fixture captures one window at one moment.** Timing isn't replayed: notifications, lazily built trees, settling. Those are left to end-to-end runs.
- **Only the focused window is saved.** The text dump searches every window, but saves the tree of the focused one only.
- **The dump tool switches an Electron app's tree on for the rest of its run,** like probing does.
- **The text dump holds page content** (titles, values, text up to 80 characters each). Read it before sharing it; it's not meant to be committed.
