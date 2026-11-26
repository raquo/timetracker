# Electron apps and the Claude desktop app

What we know about reading Electron apps' web content through Accessibility, and about the Claude desktop app in particular. General tracking techniques: [tracking-techniques.md](tracking-techniques.md). Decisions and TODOs: [PLAN.md](PLAN.md).

Marked **(verified)** where we observed it, **(inferred)** where it's our reading of the evidence, not checked against source code or docs.

## Why Electron apps need this

The window-level Accessibility data that works for native apps tells little about Electron apps: Claude's window title is always "Claude", whatever conversation is open, and `AXDocument` is empty. Electron apps aren't scriptable through Apple Events either. What they show lives in web pages, so the tracker reads the page's URL and title from the web content's Accessibility tree. Because the tree has a cost, it does this only in apps where probing found content pages, or where the user chose to ([docs/page-reading.md](../docs/page-reading.md)).

## How the tracker reads them

How Electron windows hold their pages, switching the tree on (`AXManualAccessibility`), finding the content page, observers, search cost and the dump tool: [docs/page-reading.md](../docs/page-reading.md). This file keeps what's specific to apps.

## The Claude desktop app (`com.anthropic.claudefordesktop`)

Code: [Apps/Claude.swift](../tracker/Sources/TrackerCore/Apps/Claude.swift).

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

- **⌘-click windows:** a chat or session opened in its own window records no page URL / title, only the window title (the chat's name). Cause (verified with the dump tool, 2026-11-26): the window's one web area reports `AXURL` `about:blank`, though its `AXTitle` is the chat's ("Greeting") and focus is inside it. `about:blank` isn't content, so it's skipped. The real URL isn't exposed anywhere in that window's tree. Test fixture: `claude-cmd-click-window.json`. Workarounds: see "Claude gaps" in [PLAN.md](PLAN.md).
  - **Why (inferred, not verified):** "pop-out" is our informal name for such a window, not an Electron type: every Electron window is a `BrowserWindow`, and what differs is how it gets its content. The main window usually loads an address (`claude.ai/…`), which is what `AXURL` reports. We think the ⌘-click window is created differently: the main window's page calls the web's `window.open()` with no address. Electron then creates a child `BrowserWindow` (the app can shape it in `setWindowOpenHandler`), whose page starts and stays at `about:blank`. Being same-origin with its opener, it can be rendered into directly by the opener's code (React does this with portals), so it shows the conversation while its own address never changes; the conversation URL belongs to the opener's page. Fits what we saw: an `about:blank` web area titled with the conversation's name, holding the full chat UI, with React-style DOM ids (`_r_9qs_`). Against it: nothing seen so far.
  - **To confirm:** DevTools on the ⌘-click window (Claude blocks DevTools unless `~/Library/Application Support/Claude/developer_settings.json` holds `{"allowDevTools": true}`, or Help → "Enable Developer Mode…", which writes it. Read at startup only, so quit and reopen Claude. Then ⌥⌘I, or right-click in the ⌘-click window → "Inspect Element" for that window's own page. Verified 2026-11-26). In the Console: `location.href` (expect `about:blank`), `window.opener` (expect set), `window.opener.location.href` (expect the main window's `claude.ai/…` address), `sessionStorage` (does it name the conversation?).
- **Browser pane in a Code session:** a web area nested inside the claude.ai page (iframe or `<webview>`, **inferred**). The search doesn't descend into web areas, so pages visited there aren't recorded; the time stays on the session.

## Notion (`notion.id`) (verified, 2026-11-22)

- Simpler than Claude: **one web area per window**, `https://app.notion.com/…`, no local shell page. Same native wrappers (~7 levels). 4 renderer processes with 3 windows open.
- The window title already is the page title, so the tree adds only the URL.
- Search cost: 14 elements, 3–9 ms per window. Whole tree ~1300 elements.
- URL forms:
  - Page: `/p/<Title-slug>-<page-id>`; with `#<block-id>` when opened at a block (e.g. from a link). The tracker drops fragments ("URL fragments" in [PLAN.md](PLAN.md)).
  - Database view with a page open in side peek: `/p/<database-id>?v=<view-id>&p=<peeked-page-id>&pm=s`. The window title stays the database's name; only the URL names the peeked page.
- Desktop tabs: only one web area per window, and the window had many tabs open, so only the active tab's page is attached.
- Allowlisted on 2026-11-22; since 2026-11-23 found by probing. Its rows record the page URL, with the `#<block-id>` fragment dropped.

## Slack, Obsidian, VS Code: probed with the dump tool (verified, 2026-11-22)

All three: one top-level web area per window, 13–14 elements searched, 5–14 ms.

With probing (since 2026-11-23) the allowlist is gone: Slack and Obsidian will probe to on (each shows a content page; Obsidian's says nothing, see the refinement TODO in PLAN.md), VS Code to off, though probing switches its tree on and can bring up its screen reader popup. Set them in `app_page_reading_choice` to override.

| App | Top-level page | What the tracker would record | Your choice |
|---|---|---|---|
| Slack (`com.tinyspeck.slackmacgap`) | `https://app.slack.com/client/<team-id>/<channel-id>`, title = window title (`windsurf-repairs (Channel) - ClubLocarno - Slack`) | URL with stable team and channel IDs (survive renames); the title already names channel and workspace | Leave on (the probe's result) if rules should key on IDs; otherwise off, the title is enough |
| Obsidian (`md.obsidian`) | `app://obsidian.md/index.html` for every note, title = window title (`<note> - <vault> - Obsidian <version>`, e.g. `_ 18.0.0 – Plan & TODO - Notes - Obsidian 1.15.1`) | The same constant URL for every note: Obsidian's local UI under its own `app://` scheme, outside the bundle path, so our rule counts it as content. `AXDocument` empty, so no file path either | Off (probing gives on, for nothing): no information. The title carries note and vault (but also Obsidian's version, which changes on every update: a case for title normalization). The note's file could be found from the vault path (Obsidian's `obsidian.json`) and the note name |
| VS Code (`com.microsoft.VSCode`) | `vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/…/workbench.html`, inside the bundle, so skipped | No URL. Its "Release Notes" tab is a `vscode-webview://…` web area nested inside the workbench (twice), which the search doesn't descend into. But with a file open, **`AXDocument` has the file's full path**, recorded already (window-level, for every app); the window title is the file name. Switching its tree on triggers a "screen reader detected" popup | Off (also probing's result): the window gives title and path, and the tree would keep VS Code thinking a screen reader is running. Choosing off before its first probe avoids the popup |

Lessons:
- **Local UI outside the bundle counts as content:** under a custom scheme (Obsidian's `app://obsidian.md`) or even over https (Zoom's home screen, `https://new-home-page.localhost/index.html`, seen 2026-11-23). Harmless (a constant URL), but the app gets "on" for nothing. Zoom rules out fixing this by scheme or host; see the refinement TODO in PLAN.md.
- **Editors' embedded views** (VS Code webviews, the Claude Code browser pane) are nested web areas. Not seen, by design.
- **Most apps put what matters in the window title.** Page reading only adds something in apps whose title doesn't say what's open (Claude) or where URL IDs add something rules need (Notion page IDs, Slack channel IDs). Probing turns it on wherever a content page shows, more widely than that; the "on" condition may be refined (TODO in [PLAN.md](PLAN.md)).

## Other Electron apps (not tried yet)

Installed: Arduino IDE (`cc.arduino.IDE2`, maybe served from `http://localhost`), OpenCode (`ai.opencode.desktop`, maybe `localhost` too), Chatbox (`xyz.chatboxapp.app`). Also Discord, if installed later (remote site in a shell, like Slack). Probing now decides on them by itself; the dump tool shows the search cost and which web areas it finds. Any app-specific rule goes into a file under `tracker/Sources/TrackerCore/Apps/`.
