# Electron apps and the Claude desktop app

What we know about reading Electron apps' web content through Accessibility, and about the Claude desktop app in particular. General tracking techniques: [tracking-techniques.md](tracking-techniques.md). Decisions and TODOs: [PLAN.md](PLAN.md).

Marked **(verified)** where we observed it, **(inferred)** where it's our reading of the evidence, not checked against source code or docs.

## Why Electron apps need this

The window-level Accessibility data that works for native apps tells little about Electron apps: Claude's window title is always "Claude", whatever conversation is open, and `AXDocument` is empty. Electron apps aren't scriptable through Apple Events either. What they show lives in web pages, so the tracker reads the page's URL and title from the web content's Accessibility tree. It does this only for an allowlist of apps (default: Claude), because the tree has a cost.

## How an Electron window is built

- **One window can hold several web pages.** Electron's `BrowserWindow` can contain several `WebContentsView`s (formerly `BrowserView`s): separate web pages, each with its own document and usually its own renderer process, laid out and layered like native views. A simple app uses one page for everything; apps that wrap a remote website often split into a local shell plus the remote site.
- **How they show up in the tree:** each page is an `AXWebArea` element. Separate views appear as **siblings**, each under its own native wrapper (`AXGroup` / `AXScrollArea`). An iframe or a `<webview>` tag appears **nested**: a web area inside its parent page's web area. **(inferred** from Chromium's tree layout; the sibling layout in Claude is **verified)**
- **Why split (inferred):** security (the remote site runs sandboxed in its own process, apart from the shell's privileged access to the desktop), reuse (the web team ships the site as is), and overlays (e.g. a find bar floating over the page, which the page's CSS and scripts can't break).
- **Page URLs tell them apart:** the app's own UI is loaded from inside its bundle (`file:///Applications/<App>.app/Contents/Resources/app.asar/…`); remote content from `https://…`.

## Switching the tree on

- **`AXManualAccessibility = true`** on the app element (`AXUIElementCreateApplication(pid)`) makes an Electron app build its web Accessibility tree. Designed for this purpose (assistive apps other than VoiceOver); no side effects on window animations, unlike `AXEnhancedUserInterface` (needed for Firefox / Chromium browsers, makes window moves and resizes janky). **(verified** on Claude)
- **Built lazily:** the first reads right after switching it on can come back empty. **(verified)** Our dump tool waits 2 s after switching it on.
- **The flag reads back as false** in Claude even while the tree is on, so reading it tells nothing about whether it's on. Probably the same in all Electron apps. **(verified** on Claude)
- **Apps can notice it and react.** VS Code, after our dump probe switched its tree on, showed its own popup: "Screen reader usage detected. Do you want to enable editor.accessibilitySupport…?". So switching the tree on isn't always invisible to the user; probe or allowlist an app knowing it may prompt. (Answer no in VS Code: the tracker doesn't need it.)
- **It stays on until the app quits.** Once on, the app keeps building and updating the tree for every page change; that's the cost. Not measured yet.
- **We never switch it off:** we can't tell whether something else started relying on it while we ran (and the flag can't even be read). Options and the open decision: TODO "Tracker: Accessibility tree in other apps" in [PLAN.md](PLAN.md).

## Finding the content page

What `WebAreaReader` does on every sample of an allowlisted app ([WebAreaReader.swift](../tracker/Sources/TimeTracker/WebAreaReader.swift)):

1. Search the focused window for `AXWebArea` elements: depth-first through `AXChildren`, **never descending into a web area**, up to 500 elements. So it only walks the native wrappers around the pages, not the pages' content.
2. Read each web area's `AXURL` (reported as a CFURL or a string). Skip the app's own UI and placeholders:
   - pages loaded from inside the app's bundle (the URL's path is inside the `.app`, whatever the scheme: Electron's `file://…/app.asar/…`, VS Code's `vscode-file://vscode-app/…/Visual Studio Code.app/…`)
   - `about:` pages (`about:blank`)
   - everything else counts, including local `file://` documents and custom schemes.
3. One content page left → record its URL and `AXTitle` (the document's `<title>`). Several → the one holding keyboard focus (walk `AXParent` up from the app's `AXFocusedUIElement` to a web area). None of them focused, or no content page → no URL (rather none than the wrong one).

**Cost (verified, Claude, 2026-11-22):** the search visits 20 elements, about 44 calls in all (role and children per element, then URL and title), 4–17 ms per sample, median ~8 ms. The same while Claude streams a long reply. Each call is a round trip to the app's process; Electron answers them in its main (browser) process, not the page's renderer **(inferred)**. So the tracker searches afresh on every sample instead of caching the page element, which also rules out reporting a page that's no longer shown. Apps with a bigger UI around their pages could cost more (up to 500 elements); measure each app with the dump tool before allowlisting it.

**Change events:** page content changes often don't change the window title, so for allowlisted apps the tracker also observes `AXFocusedUIElementChanged` on the app and `AXTitleChanged` / `AXLoadComplete` on the page element. Clicks trigger a sample 600 ms later, which catches the rest (e.g. clicking another conversation).

**Exploring an app:** `open -n -W ~/Applications/TimeTracker.app --args --dump-ax <bundle-id> <output-file>` reports the page search on each of the app's windows (elements visited, time, web areas found), then dumps the focused window's tree (role, subrole, title, description, value, DOM id, URL per element). Must run via `open` so it gets the tracker's own Accessibility permission. Switches the app's tree on and leaves it on.

## The Claude desktop app (`com.anthropic.claudefordesktop`)

Code: [Apps/Claude.swift](../tracker/Sources/TimeTracker/Apps/Claude.swift).

### Window and tree (verified)

- Window title always "Claude", except windows opened by ⌘-clicking a session, which are titled with the conversation name. `AXDocument` empty.
- 4 renderer processes (`Claude Helper (Renderer)`) with one window open.
- The focused window holds three web areas, siblings about 7 levels below the window:

  ```
  AXWindow "Claude"
    AXGroup "Claude" → AXGroup ×4
      AXGroup → AXScrollArea → AXWebArea  file:///…/app.asar/.vite/renderer/main_window/index.html     (Claude's shell)
      AXGroup → AXGroup → AXScrollArea → AXWebArea  https://claude.ai/…  "<conversation> - Claude Code"   (the content)
      …                                 AXWebArea  file:///…/app.asar/.vite/renderer/find_in_page/find-in-page.html  (⌘F find bar)
  ```

- The whole tree is ~550–970 elements, almost all inside the claude.ai page (sidebar, conversation, buttons with DOM ids like `_r_6_`).

### Page URLs and titles (verified)

- Claude Code session: `https://claude.ai/epitaxy/local_<session-id>`, title `<session name> - Claude Code`
- Regular chat: `https://claude.ai/chat/<uuid>`, title `<chat name> - Claude`; new chat: `https://claude.ai/new`
- Renaming a session gives a new page title on the same URL.
- Switching sessions by click or ⌘N, and between Code sessions and regular chats: one row each with the right URL and title, ~2.6 s apart.
- The page's title can briefly be just "Claude" right after switching (seen as a 5 s row before the real title).

### Session context

- The page's tree also shows the session's environment (e.g. "⏰ TIME TRACKER", under "Activity panel" → "Environment") and folder (popup button "timetracker ~/code/canvas"), ~750 elements deep. We prefer not to scrape the UI: it's slow to reach and changes with any app update.
- **Session files on disk** (undocumented, read-only use): `~/Library/Application Support/Claude/claude-code-sessions/<account-id>/<org-id>/local_<session-id>.json`, named after the ID in the page URL. Fields: `cliSessionId` (the Claude Code transcript, `~/.claude/projects/<project>/<cliSessionId>.jsonl`), `cwd`, `title`, `createdAt`, `lastActivityAt`, `lastFocusedAt`, `envScopeId`. `~/Library/Application Support/Claude/ccd-session-presets.json` maps `envScopeId` to the environment's `name`. Planned: resolve a recorded page URL to folder and environment (TODO "Claude session context" in [PLAN.md](PLAN.md)).
- **Claude Code hooks** (`SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`, …) get JSON with `session_id`, `cwd`, `transcript_path`. They report activity in a session, not which one is visible, and only cover Claude Code sessions.

### Known gaps

- **⌘-click windows:** a session opened in its own window recorded no page URL / title (6.8 s row). Cause not known (tree not built yet in the new window? a different layout?). Run the dump tool on such a window to find out.
- **Browser pane in a Code session:** a web area nested inside the claude.ai page (iframe or `<webview>`, **inferred**). The search doesn't descend into web areas, so pages visited there aren't recorded; the time stays on the session.

## Notion (`notion.id`) (verified, 2026-11-22)

- Simpler than Claude: **one web area per window**, `https://app.notion.com/…`, no local shell page. Same native wrappers (~7 levels). 4 renderer processes with 3 windows open.
- The window title already is the page title, so the tree adds only the URL.
- Search cost: 14 elements, 3–9 ms per window. Whole tree ~1300 elements.
- URL forms:
  - Page: `/p/<Title-slug>-<page-id>`; with `#<block-id>` when opened at a block (e.g. from a link). The tracker drops fragments ("URL fragments" in [PLAN.md](PLAN.md)).
  - Database view with a page open in side peek: `/p/<database-id>?v=<view-id>&p=<peeked-page-id>&pm=s`. The window title stays the database's name; only the URL names the peeked page.
- Desktop tabs: only one web area per window, and the window had many tabs open, so only the active tab's page is attached.
- Allowlisted since 2026-11-22. Its rows record the page URL, with the `#<block-id>` fragment dropped.

## Slack, Obsidian, VS Code: probed with the dump tool, not allowlisted (verified, 2026-11-22)

All three: one top-level web area per window, 13–14 elements searched, 5–14 ms.

| App | Top-level page | What the tracker would record | Verdict |
|---|---|---|---|
| Slack (`com.tinyspeck.slackmacgap`) | `https://app.slack.com/client/<team-id>/<channel-id>`, title = window title (`windsurf-repairs (Channel) - ClubLocarno - Slack`) | URL with stable team and channel IDs (survive renames); the title already names channel and workspace | Worth allowlisting if rules should key on IDs; otherwise the title is enough |
| Obsidian (`md.obsidian`) | `app://obsidian.md/index.html` for every note, title = window title (`<note> - <vault> - Obsidian <version>`, e.g. `_ 18.0.0 – Plan & TODO - Notes - Obsidian 1.15.1`) | The same constant URL for every note: Obsidian's local UI under its own `app://` scheme, outside the bundle path, so our rule counts it as content. `AXDocument` empty, so no file path either | Don't allowlist: no information. The title carries note and vault (but also Obsidian's version, which changes on every update: a case for title normalization). The note's file could be found from the vault path (Obsidian's `obsidian.json`) and the note name |
| VS Code (`com.microsoft.VSCode`) | `vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/…/workbench.html`, inside the bundle, so skipped | No URL. Its "Release Notes" tab is a `vscode-webview://…` web area nested inside the workbench (twice), which the search doesn't descend into. But with a file open, **`AXDocument` has the file's full path**, recorded already (window-level, no allowlist needed); the window title is the file name. Switching its tree on triggers a "screen reader detected" popup | Don't allowlist: the window gives title and path, and the tree would keep VS Code thinking a screen reader is running |

Lessons:
- **Local UI under a custom scheme** (`app://`, like Obsidian) passes the "not loaded from the bundle" rule. Harmless (a constant URL), but it's a sign the app has nothing for us in its web tree. If more such apps come up, also skip custom schemes whose host names the app itself (`app://obsidian.md`).
- **Editors' embedded views** (VS Code webviews, the Claude Code browser pane) are nested web areas. Not seen, by design.
- **Most apps put what matters in the window title.** Allowlist only apps whose title doesn't say what's open (Claude) or where URL IDs add something rules need (Notion page IDs, Slack channel IDs).

## Other Electron apps (not tried yet)

Installed: Arduino IDE (`cc.arduino.IDE2`, maybe served from `http://localhost`), OpenCode (`ai.opencode.desktop`, maybe `localhost` too), Chatbox (`xyz.chatboxapp.app`). Also Discord, if installed later (remote site in a shell, like Slack). Before allowlisting one, run the dump tool on it and check the search cost and which web areas it finds. Any app-specific rule goes into a file under `tracker/Sources/TimeTracker/Apps/`, and its tree switch into `WebContentProfile.known`.
