# End-to-end tests

The real tracker records into a temporary database while a test drives a small app we control, a throwaway Google Chrome or a throwaway Firefox, and checks the rows against what was on screen. The other tests run parts of the tracker on made-up or recorded input: the logic on samples, the page search on recorded trees ([diagnostics.md](diagnostics.md)). This one covers what they can't: macOS events reaching the tracker (`Tracker`, `WindowObserver`), live Accessibility reads (`Sampler`), and the whole chain down to the stored rows.

## Behaviour

- **Three tests,** one per thing driven: `targetApps` (the test app), `chrome` and `firefox`, in the suite `EndToEndTests`. Each has a run of its own (tracker, database, target apps, checks), so each can run alone, and they run one at a time.
- Run all with `tracker/scripts/e2e.sh`, or some by name: `tracker/scripts/e2e.sh chrome`. The names are the test functions', which the script reads from `swift test list`, so a new test needs no change there; an unknown name lists them. A plain `swift test` skips them. The script fails if one was skipped anyway (see "Cleanup and reruns").
- All three take over the screen for about 2.5 minutes (one test 30–60 s). Don't click or type meanwhile: that goes to whatever is in front, and the test's steps would see it (a click can move focus to another window or app). Moving the mouse is fine (see "Input idle").
- Your own tracker keeps running and records the run too (TODO in [PLAN.md](../notes/PLAN.md)). They don't clash: the instance lock is per database. Your own Chrome and Firefox keep running too, untouched.
- Needs a one-time Accessibility grant for the test's helper app, `tracker/build/e2e/E2E Helper.app` (System Settings → Privacy & Security → Accessibility → +), and the "Time Tracker" signing identity it's signed with ([tracker/README.md](../tracker/README.md)). Without either, the script stops within seconds, before the slow builds, and says what to do (see "How it works").
- Needs Google Chrome in `/Applications`. `TIMETRACKER_E2E_CHROME=<path to the app>` picks another copy; set but empty, the `chrome` test skips itself.
- Needs Firefox or Firefox Developer Edition in `/Applications` (Firefox first, if both). `TIMETRACKER_E2E_FIREFOX` works like `TIMETRACKER_E2E_CHROME`.
- `KEEP=1` keeps the run folder (databases, pages, command files, the browsers' profiles) for a look afterwards, until the next run sweeps it.
- On failure, the output names the step that failed, or lists every recorded row and every step on one timeline, in seconds from the first step.

## How it works

**The test app** (`Sources/E2ETarget`) is built three times, as "E2E Target A", "B" and "C" (bundle IDs `com.raquo.timetracker.e2e-target-a` / `-b` / `-c`): A and B to switch between, C to show only a page from its own bundle (`Contents/Resources/own.html`, its "own UI"). The test controls it through files in its folder: it writes `cmd-<n>.json` (open a window or a panel, with web pages or without; close it; navigate; run a script in a page; rename or focus a window; focus a web view), and the app answers in `ack-<n>.json` once the command has taken effect: after pages have loaded, after a script has run (with its result). The test never sends keystrokes or clicks: those go to whatever is in front, which could be one of your apps. The app quits by itself once the run folder is gone.

**The tracker** is the build copy (`build/TimeTracker.app`), which holds the Accessibility permission (same signature as the installed one), started with `TIMETRACKER_DB` pointing into the test's folder. It's stopped with SIGTERM, so it closes its last row like on a normal quit.

**The helper** (`Sources/E2EHelper`, "E2E Helper", bundle ID `com.raquo.timetracker.e2e-helper`) is a windowless app that holds the Accessibility permission and does only what needs it: moving keyboard focus in Chrome to the address bar, which the DevTools Protocol can't do, and from there back into a page. It sets `AXFocused` on that one element (the toolbar's text field described "Address and search bar", or the `AXWebArea` with a given URL) and waits until the app reports focus there (`AXFocusedUIElement`); no keystrokes or clicks. The test drives it through command files, like the test app, and starts it through LaunchServices, so macOS checks the helper's own permission rather than the terminal's. That permission is checked before anything else: by the script right after building the helper (`--check-access`), and by each test before it starts the tracker or any app (the `checkAccess` command). Either stops the run with a message naming the app to add in System Settings.

**The poll is turned off** (`TIMETRACKER_POLL_SECONDS` set to an hour, [sampling.md](sampling.md#when-the-tracker-samples)), so every change must be caught by its event. With the 5 s poll, a step whose event the tracker ignored would still pass about 1 time in 4, whenever the poll came within the 1.5 s after the step. Where a step's change sends no event, or a step changes nothing (so it would pass without the tracker having looked), the test asks the tracker for a sample (SIGUSR1). The poll itself isn't covered.

**Pages** are local HTML files in the run folder, outside the apps' bundles (pages loaded from an app's own bundle aren't content, see [page-reading.md](page-reading.md)). Titles carry a run ID.

**Chrome** is a second copy of the installed one, started with a throwaway profile in the run folder (`--user-data-dir`), so it runs as its own process beside yours, with none of your tabs, sign-ins or keychain entries (`--use-mock-keychain`). The test drives it through DevTools (`--remote-debugging-port`): it opens tabs, windows and DevTools, navigates, switches tabs, runs scripts in pages and brings Chrome to the front, never clicks or types. It has the same bundle ID as your Chrome, so it's told apart by pid. Its pages come from a small HTTP server in the test on 127.0.0.1, since Chrome doesn't allow `history.pushState` on `file://` pages. It starts in the background and comes to the front once its page has loaded, so the tracker's first look at it (its first page probe) sees a loaded page.

**Firefox** runs the same way: a second copy with a throwaway profile (`-profile … -no-remote -new-instance`, so it doesn't hand the run over to your Firefox), the same bundle ID as yours, told apart by pid, and pages from the same server. It's driven through WebDriver BiDi (`--remote-debugging-port`): one session for the whole run, since Firefox allows one and keeps it after its connection closes. Three things differ from Chrome:
- **Bringing it to the front** goes by pid (`NSRunningApplication.activate`): BiDi's `browsingContext.activate` focuses the window but leaves Firefox behind, and opening the app by its bundle could reach your Firefox.
- **Its first page may be recorded up to 2 s late.** Firefox builds its page tree only once something asks, so the tracker's first probe can find only the window; the retry 2 s later finds the page ([page-reading.md](page-reading.md#probing)). So that step may record the window without a page first, and its changeover is 2 s longer, as is its hold.
- **Its first page is in a tab opened through BiDi,** and the tab Firefox started with is closed. That tab keeps keyboard focus in the address bar, and Firefox gives focus back there whenever it's shown again, so a step back to it would fail its focus check. Tabs opened through BiDi have focus in the page.

**App switches** go through LaunchServices (`NSWorkspace.openApplication`, like clicking the app's Dock icon), which works from a background process. The front app is read from `lsappinfo`, since `NSWorkspace.frontmostApplication` only updates while the asking process's main run loop runs.

**Steps check their own premise** before they count: where a step moves keyboard focus, the test asks the pages (`document.hasFocus()`, the iframe's `activeElement`) that focus is where the step says, and fails otherwise. In the browsers, every step that changes the tab or window checks that the tab is shown (`document.visibilityState`) and has focus, with the browser in front. Without that, a step whose action silently did nothing would pass whenever the tracker kept recording the previous state.

**Steps** are held 2.5 s each. Currently:
- **In the test app** (`targetApps`): a plain window; a web page; navigating; the page renaming itself (no event in WebKit, so sampled on request: this step also shows the request works); changing only the fragment (not recorded, so no change); a URL with a secret (`?token=` and a fragment, recorded scrubbed); renaming the window; another window; another app and back; two pages side by side with focus in neither, then each; a page with an iframe, with focus inside the iframe (still the outer page); a page that renames itself 450 ms after loading, between the tracker's first two looks, so settling must hide the first title; an app showing only its own UI (no page, and page reading stays undecided); a panel (`AXFloatingWindow`, not main); the app in front with no window. The iframe is `srcdoc`, so it shares the outer page's origin: a script can't move focus into another origin's frame without a click, and each `file://` page is its own origin.
- **In Chrome** (`chrome`): a page; navigating; the page renaming itself; `history.pushState` to a URL with a secret, with a new title; changing only the fragment; a URL with a secret; a new tab, then back to the first; a new window, then closing it; DevTools docked in the tab's window (opened with `Target.openDevTools`), with focus in DevTools, then in the address bar (moved by the helper; two content pages and focus in neither, so no page is recorded, [page-reading.md](page-reading.md#finding-the-content-page)), then in the page (the helper again: `Page.bringToFront` leaves focus in the address bar), back in DevTools (`Page.bringToFront`), then DevTools closed; Chrome's own page (`chrome://version/`); another app and back. The window's document is checked too: Chrome reports the tab's URL there, scrubbed like the page URL ([url-scrubbing.md](url-scrubbing.md#window-documents-axdocument)).
- **In Firefox** (`firefox`): the same, except its own pages, and with one more exception: `history.pushState` without a new title. That sends no event the tracker listens for, but Firefox updates the page's URL at once, so a sample on request records it ([page-reading.md](page-reading.md#background)). The window has no document.

**Not stepped through:**
- In Chrome, `pushState` without a new title: it sends no event and Chrome keeps the old URL in the tree until the page's next change ([page-reading.md](page-reading.md#limitations)), so even a sample on request may not see it.
- Firefox's own pages (`about:…`): BiDi refuses to load them ("not allowed in this context").

## What's checked

- **Each step's rows:** from 1.5 s after a step was done (its commands answered) until the next one, every row matches what the step showed: app (bundle ID, install path, name), window title, role and subrole, main and full-screen flags, page URL, page title and window document. Also not locked. Not the idle flag (see "Input idle"). The 1.5 s allow for an event (300 ms), settling (400 ms) and slack; rows mostly start 0.3–0.7 s after the step.
- **Nothing in between:** during those first 1.5 s, the row in progress (the previous state) may go on, but any row that starts must already be the step's. So a passing state recorded on the way, such as a page half loaded or the old title with the new URL, fails the step. The one exception is Firefox's first step, which may record the window without its page first (see "How it works").
- **No missed changes:** a missed change shows as the previous state recorded during the step, which fails it as above. Each test's first step also checks that its row didn't start before it: the test waits for the tracker to record the state before (the test app in front, no window), so an earlier start means a change seen too early.
- **Settling backdates:** in the settling step, the row must start before the page renamed itself. That proves the tracker saw the first title and settling hid it; a row starting later means the step didn't test settling at all, and fails too.
- **Rows by time, not by title:** the temporary database holds only this run, so rows are matched to steps by time. A wrong or missing title then fails the test, rather than hiding the row.
- **No gaps or overlaps** between rows during the run, and **no splits for nothing:** two rows in a row never record exactly the same (idle flag included).
- **The last row ends when the tracker was stopped** (between sending SIGTERM and its exit), not at its last sample.
- **Page reading mode:** each app that showed a page is decided on (`has_content_pages` 1 in `tracker_app_page_probe`, [page-reading.md](page-reading.md#page-reading-mode)) during its first step with one, not before and not later. An app that never did (C) has been probed but isn't decided.

The latency allowance can't tell a boundary that's a few hundred milliseconds late (e.g. settling moving the start to the confirming sample) from a normal one; the logic tests cover that.

## Input idle

The test makes no input (no clicks or keystrokes, see "How it works"), so after a minute without real input the tracker marks the run's rows input idle ([idle-and-away.md](idle-and-away.md)), and moving the mouse ends that. The checks ignore the idle flag, so a run can start any time and the mouse can move during it.

That's safe because going idle changes only the flag. The idle stretch is backdated to the last input, but never past the start of the row in progress (`Recorder`), and that row started with the test's step. So the step's row is rewritten as the same app, window and page marked idle, from the same start. Ending idle mid-step splits the step's row into two rows with the same content, which both match.

Not checked, then: that idle starts after 60 s without input. The logic tests cover idle; a test that makes no input can't. (Its clock can't be reset either: only real input does that, declaring user activity with `IOPMAssertionDeclareUserActivity` doesn't, checked 2026-11-26.)

## Cleanup and reruns

- **Each test is isolated:** a folder of its own, named after it, in the run's temporary folder; its own database; a new run ID in titles.
- **A test's folder must be new,** or the test fails: an old database there would let it check a previous run. Likewise a missing app or folder fails it, rather than skipping it.
- **A skipped test fails the script:** `swift test` passes a test that's skipped (an environment variable that didn't reach it, a filter that matched nothing), so each test leaves `checked` in its folder (its step count, or why it skipped itself: its browser set empty), and the script fails if a test it ran has none. A browser variable that isn't set at all fails the test, since the script always sets it.
- **A lock** (`$TMPDIR/timetracker-e2e.lock`, holding the run's pid) stops two runs at once: they would fight over the front app. A lock whose pid is gone, or now belongs to something other than `e2e.sh`, is taken over. A lock without a pid is a run just starting, so the script stops.
- **On exit** the script kills what the run started (the test process and its children; the test apps, the helper and the browsers by their arguments, which name the run folder; the build copy's tracker) and deletes the folder, the browsers' profiles with it. The test itself also stops them (the browsers by asking them to quit, so they take their helper processes down themselves, then anything still naming their profiles), and brings back the app that was in front before, if it's still running. Ctrl-C and SIGTERM are handled at once: the test runs in the background while the script waits.
- **If the script is killed outright** (SIGKILL, so no exit handler), a watchdog it started does the same cleanup once it's gone. The watchdog survives the terminal closing. Also, the test apps quit once the run folder is gone.
- **After a run that died** without even that, the next run sweeps the leftovers first: test apps, browsers, any tracker running from the build copy (a `--dump-ax` or `--watch-ax` run from it too), old run folders.

## Not covered

- **Other real apps.** Safari: not tried. Electron apps (Claude, Notion, Slack) allow one running copy, so they'd need a way to run more (TODO in [PLAN.md](../notes/PLAN.md)); until then the recorded trees cover them ([diagnostics.md](diagnostics.md)).
- **Idle, lock, sleep:** need real input or real system events (see "Input idle").
- **The poll:** turned off, see "How it works".
- **Full screen:** entering it moves the window to its own Space, slowly and visibly.
- **Clicks** as a trigger (the test doesn't click), and so focus moved by a click, e.g. into a cross-origin iframe.

## Why

- **One suite, its tests spread across files,** not one suite per file: Swift Testing runs suites in parallel, and two tests at once would fight over the front app.
- **A separate helper app holds the Accessibility permission,** because some steps need it (focus in Chrome's address bar) and the test process can't have it.
- **The helper is signed with the tracker's identity, never ad hoc:** a grant is tied to the signature, and an ad-hoc one changes on every build, so the grant would silently stop working. The script fails if the identity is missing.

## Code

- `tracker/Sources/E2ETarget/main.swift`: the test app.
- `tracker/Sources/E2EHelper/main.swift`: the helper.
- `tracker/Tests/TrackerE2ETests/Helper.swift`: driving the helper (`E2E.Helper`).
- `tracker/Tests/TrackerE2ETests/CommandFiles.swift`: the command files the test app and the helper read (`E2E.CommandFiles`).
- `tracker/Tests/TrackerE2ETests/EndToEndTests.swift`: the suite (`EndToEndTests`) and what each test does around its steps (`run`).
- `tracker/Tests/TrackerE2ETests/TargetAppTests.swift`, `ChromeTests.swift`, `FirefoxTests.swift`: the tests (`targetApps`, `chrome`, `firefox`) and their steps, each an extension of the suite.
- `tracker/Tests/TrackerE2ETests/Harness.swift`: the harness: a run (`E2E.Run`: start, steps, checks), the test app's copies (`E2E.Target`), the pages, what's expected and recorded.
- `tracker/Tests/TrackerE2ETests/Chrome.swift`: Chrome (`E2E.Chrome`), driven through DevTools.
- `tracker/Tests/TrackerE2ETests/Firefox.swift`: Firefox (`E2E.Firefox`), driven through WebDriver BiDi.
- `tracker/Tests/TrackerE2ETests/BrowserSupport.swift`: what they share: waiting on page scripts (`E2E.Browser`), the WebSocket connection (`E2E.BrowserSocket`), the page server, quitting.
- `tracker/scripts/e2e.sh`: build (the helper first, then its permission check), pick the tests, lock, sweep, run, clean up.
