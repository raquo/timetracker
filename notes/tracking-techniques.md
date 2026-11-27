# Tracking techniques

How the tracker gets its data on macOS, what each technique costs, and what we've learned about specific apps. Decisions and TODOs live in [PLAN.md](PLAN.md); Electron and Claude specifics in [electron-and-claude.md](electron-and-claude.md); this file is the reference.

## Hard requirement: no keylogging

The tracker never records keystrokes, typed text, or which keys were pressed, and never installs a keyboard event monitor or event tap, not even as a trigger. Input is only ever used as "time since last input" (idle) and "a click happened" (a trigger to sample). Clicks: never their position, target or button.

## The three ways to read app data

| | Accessibility, window level (in use) | Apple Events (not needed so far) | Accessibility, page content (browsers and Claude, in use) |
|---|---|---|---|
| **What it gives** | App, window title, document path (when the app reports it), window role / subrole, main window, full screen | Whatever the app's scripting dictionary offers: browser tab URL and title, Finder folder, Mail message | URL and title of the web page, plus anything rendered on it (sidebars, panels, labels) |
| **Which apps** | All apps | Only scriptable apps: Safari, Chrome family (Chrome, Arc, Brave, Edge, Vivaldi), Finder, Mail. Not Firefox, not Electron apps | Apps with web content: Electron apps (Claude, Slack, Notion, Discord…), Firefox, Safari, Chromium browsers |
| **Permission** | Accessibility, granted once for all apps | Automation, one prompt per target app ("… wants access to control Google Chrome"), can be denied | Accessibility, nothing extra |
| **Cost to the other app** | Close to none | Small, per request | Builds and maintains a tree of the whole page for as long as it runs (Electron: once switched on; browsers: once any Accessibility client reads it). Not measured yet |
| **Cost to the tracker** | A few IPC calls per sample | One request per sample; can hang on a busy app, so needs a timeout, off the main thread | Searches the window's UI around the pages on every sample (Claude: 20 elements, 4–17 ms, the same while it streams a reply; Firefox 16 elements, 12 ms; Safari 22, 23 ms; Chrome 56, 16 ms) |
| **Change events** | Yes: focused window and title changes (`AXObserver`) | None: polled | Some: page title changes and `AXLoadComplete`. Clicks catch the rest |
| **Consistency** | Everything read from one window element | URL and title of one tab in one request: a natural cross-check | URL and title from the same page element; window and page read separately |
| **Stability** | Stable, documented APIs | Stable, documented dictionaries | Undocumented tree layout, can change with any app update |

**Why Apple Events fit poorly with the rest of a sample.** They aren't asynchronous: from our side each request is a blocking request and reply, like an Accessibility read. The problems are elsewhere:
- **No change events ("polled").** An app sends nothing when a value we'd read through Apple Events changes. We learn of a change only when something else makes us ask: an Accessibility event, a click, or the 5 s poll. Where the change also shows in the window title (most browser tab switches), the title event covers it. A URL-only change waits for a click or the poll, so its boundary is up to 5 s late ([docs/sampling.md](../docs/sampling.md), "Late boundaries").
- **A separate read, of a possibly different window.** The request is a second round trip, made after the Accessibility reads, and the app may answer it later still, since scripting requests wait for its main thread (a busy app replies late or not at all, hence the timeout). So the URL can describe a later moment than the window title read just before. And `front window` is the app's notion of its frontmost window, which can differ from the Accessibility focused window: a title from one window next to a URL from another (consistency #2 in [docs/record-consistency.md](../docs/record-consistency.md)). Combining the two would need a cross-check, such as the window title read again after the request.
- **A permission prompt per app,** which the user can deny.

Within one app's Apple Events reply the values do agree: a tab's URL and title come in one request.

In short: window-level Accessibility is the cheap baseline for every app; page-content Accessibility gives page URLs in browsers and Electron apps without extra permissions, but depends on undocumented tree layouts; Apple Events are the stable fallback for scriptable browsers if that breaks.

## Signals and APIs

| Signal | macOS source | Permission | Status |
|---|---|---|---|
| Frontmost app | `NSWorkspace.frontmostApplication`, `didActivateApplicationNotification` | none | recorded |
| App identity | `bundleIdentifier`, `bundleURL`, `executableURL`, `localizedName` on `NSRunningApplication` | none | recorded |
| Window title | `AXFocusedWindow` → `AXTitle` | Accessibility | recorded |
| Window kind | `AXRole`, `AXSubrole`, `AXMain`, `AXFullScreen` on the focused window | Accessibility | recorded |
| Document / file path | `AXDocument` on the focused window | Accessibility | recorded where apps report it (see below) |
| Page URL / title in web content | Electron: `AXManualAccessibility` on the app first. Then `AXWebArea` → `AXURL`, `AXTitle` (or `AXDescription`) | Accessibility | recorded for apps where probing found content pages (browsers, Claude, …; see [docs/page-reading.md](../docs/page-reading.md)) |
| Safari / Chromium URL, alternative | Apple Events: `URL` and `title` of `active tab of front window`, with a timeout, off the main thread | Automation (per browser) | not needed so far |
| Idle | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, anyInputEventType)` | none | recorded |
| Lock / sleep / wake | `NSWorkspace` `willSleep` / `didWake`; `com.apple.screenIsLocked` / `screenIsUnlocked` distributed notifications; at startup, `CGSessionCopyCurrentDictionary` (`CGSSessionScreenIsLocked`) | none | recorded |
| Video / call while idle | Power assertions: `IOPMCopyAssertionsByProcess`, type `PreventUserIdleDisplaySleep` | none | recorded (see [docs/idle-and-away.md](../docs/idle-and-away.md#presence-signals)) |
| Camera / mic in use | CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere`; mic: CoreAudio's audio process list (`kAudioProcessPropertyIsRunningInput`), skipped while no device that has an input is running (`kAudioDevicePropertyDeviceIsRunningSomewhere`, for input or output) | none | recorded (same) |

## When the tracker samples

Triggers, settling, sleep and late boundaries: [docs/sampling.md](../docs/sampling.md).

Verified on 2026-11-22:
- Firefox tab switches ~2 s apart: one row each (1.6–3.0 s), not snapped to the 5 s poll, so title events work.
- Claude: switching Code sessions by click and ⌘N, switching to regular chats (`/new`, `/chat/…`) and back: one row each with the right page title and URL, ~2.6 s apart. Renaming a session shows up as a new page title on the same URL.


## What apps expose

### Document paths (`AXDocument`)

- **TextEdit, Preview** and most document-based Cocoa apps: full `file://` URL (stored as a path).
- **Finder:** has the attribute, leaves it empty. The folder is available through Apple Events (`target of front window`), which the tracker doesn't read yet (TODO "Finder folder" in [PLAN.md](PLAN.md)). So Finder rows have only the window title, usually the folder's name.
- **IntelliJ IDEA:** has the attribute, leaves it empty. The window title is `project – file` (e.g. `timetracker – .gitignore`).
- **VS Code:** full `file://` URL of the open file (empty on non-file tabs such as Welcome or release notes). With a folder open, the window title is `<tab> — <folder name>` (e.g. `build.sbt — HeartAI`), but the folder's path isn't reported anywhere; its `window.title` setting can add it (`${rootPath}`).
- **Firefox, Claude, Notion, Slack, Obsidian:** no path.

### Claude desktop app and other Electron apps

How the tracker reads web content (Electron and browsers alike): [docs/page-reading.md](../docs/page-reading.md). Claude's page URLs and titles, its session files and known gaps, and other Electron apps: [electron-and-claude.md](electron-and-claude.md).

### Browsers (verified 2026-11-22: Firefox Developer Edition, Safari, Chrome)

- **How the tracker reads them** (the shown tab's web area, titles in `AXDescription`, tab strips skipped, lazily built trees): [docs/page-reading.md](../docs/page-reading.md). Firefox's path to the web area: window → `main-window` → `tabbrowser-tabpanels` → tab panel → scroll area → web area.
- **Windows without a page:** Chrome's "Sign in with Google" popup (subrole `AXUnknown`) has no web area the search finds, so no URL.
- **Firefox Picture-in-Picture player (dumped 2026-11-23):** a window titled "Picture-in-Picture" (localized), subrole `AXStandardWindow`, `AXMain` true, no `AXDocument`. Its one web area is `about:blank` (a placeholder, so no URL is recorded), holding the video (`domId=playervideo`) and controls (`close`, `unpip` "Send back to tab", a timestamp like `23:24 / 31:38`). Nothing in it names the source tab or its URL. So rows for a focused PiP player have the window title and no page. Guessing the page from another window would break "every row describes one real moment": the source tab needn't be the one shown. Time spent watching PiP while another app has focus is the "video / call" signal's job, not this.
- **Firefox:** a row titled just "Firefox Developer Edition" (the bare app name) shows up for 2–5 s now and then while switching between populated tabs, in a standard main window. Cause unknown; the URL recorded with it next time may tell.

## Turning on an app's web Accessibility tree

Electron's `AXManualAccessibility`, browsers needing no switch, `AXEnhancedUserInterface` and why the tracker doesn't set it, and the dump tool: [docs/page-reading.md](../docs/page-reading.md).

## Gotchas

- **Signing vs. permissions:** grants are tied to the code signature. Rebuilding with an ad-hoc or changed signature silently revokes them (empty titles, no error). Sign with a stable identity. A self-signed certificate shows as `CSSMERR_TP_NOT_TRUSTED` in `security find-identity`; that's fine.
- **Keychain prompt on build:** `codesign` needs Keychain access to the signing key; if "Always Allow" wasn't chosen, the build blocks on a dialog.
- **Responsible process:** a binary launched from a terminal gets the terminal's permissions, not its own. Run the bundle via launchd or `open` to test permission-dependent behaviour.
- **Apple Events can hang** when the target app is busy: always time out.
- **Browser Accessibility trees** make the browser do more work once built; the path to the web area may change across versions.
