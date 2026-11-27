# Page reading

_(**Note:** this document covers a complex topic, and unfortunately does not meet the quality standard. It's hard to read. Keep it updated as best as you can, but don't use it as a model for other documents.)_

*Page reading* is how the tracker records which web page is open in the focused window: its URL and title. It matters for apps that show what's open only inside a web page. Claude's window title is always "Claude", whatever conversation is open, and a browser's window title doesn't include the URL.

Related: what the columns mean, [data-model.md](data-model.md); when samples are taken, [sampling.md](sampling.md); what specific apps expose, [electron-and-claude.md](../notes/electron-and-claude.md) and [tracking-techniques.md](../notes/tracking-techniques.md).

## Behaviour

**What's recorded.** Every interval (a `tracker_interval` row) has a page URL and a page title (`page_url_id`, `page_title_id`). They describe one web page: the *content page* shown in the focused window. Both are NULL when the window shows no content page, or when page reading is off for that app. URLs are scrubbed before they're recorded ([url-scrubbing.md](url-scrubbing.md)).

**How the content page is found.** macOS's Accessibility API shows each web page in a window as a *web area*, an element with the page's URL and title. A window can hold several. Some show content: a website, a conversation, a document. Others are the app's own UI, built as a web page and loaded from inside the app (Claude's sidebar shell, its find bar), or empty placeholders (`about:blank`). The tracker skips those. If exactly one page is left, that's the content page. If several are left, the content page is the one holding keyboard focus; if none of them holds it, nothing is recorded. Details: [Finding the content page](#finding-the-content-page).

**Page reading mode.** Searching a window costs the tracker a few milliseconds, and an Electron app (Claude, Slack, Notion…) builds its web tree only once the tracker switches it on, which costs that app CPU and memory for the rest of its run. So each app has a *page reading mode*: on, off, or probing.
- **On:** the tracker reads the app's content page on every sample.
- **Off:** it never reads the app's pages.
- **Probing:** the tracker hasn't decided yet. It searches the app's window about once a minute, and records no page meanwhile. As soon as a search finds a content page, the app's page reading mode becomes on. If none is found in 30 min of use, it becomes off.

Every app starts out probing. The user can override the outcome for any app. Details: [Page reading mode](#page-reading-mode).

**When the mode is on,** the tracker also watches the page for changes, so a new conversation or page is recorded within a second ([sampling.md](sampling.md)).

## Finding the content page

The tracker searches the focused window afresh each time: on every sample of an app whose page reading mode is on, and on every probe of an app that's probing. Code: `PageSearch`.

1. **Collect the web areas.** The tracker walks the window's Accessibility tree depth-first (`AXChildren`) and collects every `AXWebArea`. It never goes inside a web area, nor inside an `AXToolbar` (a browser's tab strip), and stops after visiting 150 elements (the *search budget*). So it walks only the app's native containers around its pages, never the pages' content.
2. **Drop the pages that aren't content.** For each web area the tracker reads its URL (`AXURL`), and drops the page if:
   - **It was loaded from inside the app's bundle,** whatever the scheme: the URL's path is inside the `.app`. Examples: Claude's `file:///Applications/Claude.app/Contents/Resources/app.asar/…`, VS Code's `vscode-file://vscode-app/…/Visual Studio Code.app/…`. This check isn't applied to `http` and `https` URLs, whose path is on a server, not on disk.
   - **Its URL is `about:blank`,** or it has none. Such a page is usually an empty placeholder, such as Firefox's Picture-in-Picture player. It's dropped even when it has a title: Claude's ⌘-click windows show a conversation in an `about:blank` page titled with the conversation's name, and record only the window title (see [Limitations](#limitations)).

   Every other page is a content page: websites, local `file://` documents, browsers' own pages (`chrome://new-tab-page/`, `about:newtab`), app-private schemes outside the bundle (Obsidian's `app://obsidian.md/index.html`). A page whose URL can't be scrubbed is dropped too, so no URL is ever recorded unscrubbed.
3. **Read each content page's title:** `AXTitle`, which holds the document's `<title>` in Chrome. Firefox and Safari leave it empty and put the title in `AXDescription`, which is read instead.
4. **Pick the page to record:**
   - **One content page:** that one is recorded.
   - **Several** (a split view, for example): the one holding keyboard focus is recorded. To find it, the tracker starts at the app's focused element (`AXFocusedUIElement`) and walks up through `AXParent`, at most 100 steps, until it reaches one of the content pages. On the way it may pass other web areas: focus is often in an iframe inside the page, and an iframe is a web area of its own (Google Docs types into one).
   - **None, or several and none of them focused:** no page is recorded.

**Example: Claude's main window** holds three web areas side by side: Claude's shell (`file:///…/app.asar/…/index.html`), the conversation (`https://claude.ai/chat/<id>`, titled `<chat name> - Claude`), and the ⌘F find bar (`file:///…/app.asar/…/find-in-page.html`). The shell and the find bar are loaded from the bundle, so they're dropped; the conversation is recorded.

### Watching the page for changes

In an app whose page reading mode is on, a page can change while the window title stays the same (Claude switching conversations). So besides the window events every app gets ([sampling.md](sampling.md)), the tracker also listens for:

- the app's keyboard focus moving (`AXFocusedUIElementChanged`);
- the recorded page's title changing (`AXTitleChanged`);
- any page in the app finishing loading (`AXLoadComplete`). App-wide, not only on the recorded page: a navigation can replace the page element (WebKit makes a new one per document), and the old element reports nothing more, so a navigation in a window whose title stays the same would wait for the 5 s poll. Found by the [end-to-end test](end-to-end-tests.md). Cost: a page with many frames (ads, embeds) reports a load per frame, each asking for a sample; they arrive in bursts that coalesce into one sample (300 ms, [sampling.md](sampling.md)).

Clicks catch most of the rest. Apps that are probing get none of these. Code: `WindowObserver`.

## Page reading mode

Each app's page reading mode is on, off or probing. It decides only whether the tracker reads the app's pages: the window title, kind and document path are read for every app, always. Code: `PageReadingMode`, `PageReadingPolicy`.

Two things set it:

- **The probe result,** which the tracker finds out by probing: does the app show content pages, yes or no. Until then there's no probe result.
- **The user's choice,** set per app in the UI: on, off, or auto (the default). Auto means "follow the probe result". The user can also request a *re-probe*, which makes the tracker probe the app again even though it has a probe result.

On every sample, the tracker works out each app's page reading mode like this:

1. If the user's choice is on or off, the mode is that.
2. Otherwise (auto), if there's a probe result and no re-probe was requested after it: on if the app shows content pages, off if not.
3. Otherwise, probing.

### Probing

A *probe* is one search of the focused window of an app that's probing.

- **When:** a sample of a probing app makes a probe if its focused window isn't the one last probed in that app (or the app was relaunched), or if that probe was 60 s or more ago. Other samples of that app don't search at all, and record no page. The last probe is remembered per app, so switching back and forth between apps doesn't probe the same window again within the minute.
- **Electron apps get their web tree switched on before their first probe** (see [The Electron tree switch](#the-electron-tree-switch)), since they show no pages without it.
- **A probe that finds a content page ends probing:** the probe result is yes, so the mode becomes on (unless the user chose off). That same sample already records the page.

### When probing ends with no

**The probe result becomes no after 30 min of use in which no probe found a content page.** Only time in which a probe could have happened counts towards the 30 min:

- the app was frontmost, with a focused window, and the tracker had the Accessibility permission;
- the user wasn't input-idle, and the screen wasn't locked;
- the app was probing, and had been probed at least once since the tracker started.

The tracker adds up the time between consecutive samples, counting at most 10 s per step, so sleep, hangs and clock jumps add almost nothing. The total isn't saved: when the tracker restarts, it starts again from zero. So an app used less than 30 min per tracker run stays probing.

### Where the choice and the probe result are stored

Each is stored in a table owned by whoever decides it, so neither the tracker nor the server writes the other's tables ([architecture.md](architecture.md)):

- **The user's choice:** the server-owned table `app_page_reading_choice`, written from the UI. Columns: `identifier_type`, `identifier`, `page_reading_choice` (0 = auto, 1 = on, 2 = off) and `reprobe_requested_at_ms` (nullable). The tracker only reads it, and works without it: if the table doesn't exist, every app's choice is auto. Rows with unknown values are skipped, with a warning in the log. Until the server exists, the table can be created by hand ([tracker/README.md](../tracker/README.md#page-url-and-title-from-app-web-content)).
- **The probe result:** the tracker's table `tracker_app_page_probe` ([data-model.md](data-model.md#page-probe-results-tracker_app_page_probe)). An app's row is written on its first probe, when its probe result is found, and when the tracker quits or the Mac sleeps, not on every probe.

**Both tables are keyed by app identity** (the bundle ID, or else the executable path; [data-model.md](data-model.md#app-identity)), so moving or updating an app keeps its choice and its probe result.

**The tracker notices the user's edits** by checking `PRAGMA data_version` on every sample. It re-reads the choices only when another connection has written to the database.

## The Electron tree switch

**Electron apps build their web Accessibility tree only when asked.** The tracker asks by setting `AXManualAccessibility = true` on the app's Accessibility element. Code: `ElectronTreeSwitch`.

- **Which apps:** those whose bundle contains `Contents/Frameworks/Electron Framework.framework`, whatever they're called. There's no list of apps.
- **When:** the first time the tracker searches the app in each run of the app. A run is identified by the app's pid and launch date, so a later app that reuses the pid isn't mistaken for it. If setting the flag fails, it's logged and tried again on the next search.
- **It's never switched off.** The app keeps building and updating the tree until it quits. Whether to switch it off, and how, is undecided: TODO "Switching it off" in [PLAN.md](../notes/PLAN.md).

## Cost

**Cost to the tracker:** each search visits a number of elements and makes a few Accessibility calls for each (role, children), plus URL and title per web area. Each call is a round trip to the app's process. An app whose page reading mode is on is searched on every sample; a probing app about once a minute. Measured with the dump tool ([diagnostics.md](diagnostics.md#the-dump-tool)):

| App | Elements visited | Time per search |
|---|---|---|
| Claude | 20 (~44 calls) | 4–17 ms, median ~8 ms; the same while it streams a long reply |
| Firefox | 16 | 12 ms (137 elements and 60 ms before toolbars were skipped) |
| Safari | 22 | 23 ms |
| Chrome | 56 | 16 ms |
| Notion | 14 | 3–9 ms |
| Slack, Obsidian, VS Code | 13–14 | 5–14 ms |

A search in an app without pages stops at the search budget, 150 elements.

**Cost to the app being read: not measured yet** (TODO "Measure its cost" in [PLAN.md](../notes/PLAN.md)). An app whose web tree is on keeps that tree up to date on every page change. Browsers usually pay this anyway (see [Background](#background)). Electron apps pay it only because the tracker switched their tree on.

## Why

- **The Accessibility tree, not Apple Events.** One permission, already granted, covers every app. Apple Events need an Automation prompt per app, don't work in Firefox or Electron apps, and fit poorly with the rest of a sample ([tracking-techniques.md](../notes/tracking-techniques.md)). They stay a fallback in case a browser's tree layout breaks. The price is that the tree layout is undocumented.
- **Never going inside web areas or toolbars.** A page's content can be thousands of elements (Claude's: ~550–970); the containers around it are a few dozen. A browser's tab strip was most of Firefox's search before toolbars were skipped. The cost: web areas nested inside a page aren't found (see [Limitations](#limitations)).
- **A fresh search every time, no cached page element.** It's cheap (see [Cost](#cost)), and a cached element could keep reporting a page that's no longer shown.
- **Only pages from the app's bundle and `about:blank` pages are dropped.** Those are almost never content; anything else might be. The tracker records generously and leaves filtering to the server ([tracker-principles.md](tracker-principles.md)). Rejected: telling content apart by scheme or host. Counting only `http(s)` pages would have excluded Obsidian's constant `app://` page, but not Zoom's own UI, which it serves at `https://new-home-page.localhost/index.html`.
- **No page rather than a guess** when several pages are left and none holds focus. A wrong URL would put time under the wrong project; a missing one only loses detail ([record-consistency.md](record-consistency.md)).
- **Probing, not a fixed list of apps.** The list had to be kept by hand and missed apps nobody thought of. Probing finds pages in any app, including document-based apps whose trees we haven't seen.
- **One content page is enough for a probe result of yes.** Deliberately generous: an app wrongly set off loses its pages for good, while an app wrongly set on costs only a cheap search per sample, and the user can choose off.
- **Probing once per window and once a minute, without watching for changes.** Most apps never get a probe result (they're used less than 30 min per tracker run), so probing must cost little.
- **Time when no probe could happen doesn't count towards the 30 min.** While the screen is locked, the user is idle, the app has no focused window, or the Mac sleeps, no probe runs, so that time says nothing about whether the app has pages.
- **The user's choice and the probe result in separate tables.** Each side writes only its own table, and the probe result stays a fact the UI can show next to the user's choice ("auto: no pages found on …"). Neither table's columns are called "mode" or "enabled", which would hide who decided.
- **Keyed by app identity, not by path or name.** An app's choice and probe result survive updates and moves. An unbundled program that moves counts as a new app and is probed again, which is the safe side.
- **Electron apps recognized by their framework,** so there's no list to maintain.
- **Never switching the tree off.** The tracker can't tell whether something else (a screen reader, another assistive app) has started relying on it, since Electron reports the flag as false even while the tree is on. Switching it off under such an app would break it.
- **A search budget of 150 elements.** Apps with pages need 13–56; the budget mainly caps the cost of a probe that finds nothing.

## Background

- **An Electron window can hold several web pages.** Each `WebContentsView` in a window is a separate page, and shows up as a web area next to the others, each inside its own native container. An iframe or `<webview>` shows up nested inside its page's web area. (Side by side: observed in Claude. Nesting: inferred from Chromium's tree.) An app's own UI is loaded from inside its bundle (`app.asar`); remote content over `https`.
- **`AXManualAccessibility`** is Electron's switch for assistive apps other than VoiceOver. Unlike `AXEnhancedUserInterface`, it doesn't make window moves and resizes slow. Observed in Claude:
  - the tree is built lazily, so the first reads right after switching it on can come back empty;
  - the flag reads back as false even while the tree is on.
- **Apps can notice the switch.** VS Code, with its tree switched on, asks "Screen reader usage detected. Do you want to enable editor.accessibilitySupport…?". The tracker doesn't need that setting.
- **Browsers show the current tab's page without any switch:** one web area with its URL, about 5 levels below the window. Background tabs aren't in the tree. `AXManualAccessibility` isn't supported (error -25205) and isn't needed. Observed in Firefox Developer Edition, Safari and Chrome.
- **A browser's tree is often on anyway.** With the tracker stopped, Firefox's `about:support` showed accessibility as off right after launch, and "Activated" a few seconds later: another app with Accessibility access (likely a window manager) had turned it on. Where that happens, reading browser pages costs the browser nothing extra.
- **Browser trees are built lazily too:** the first read after a browser starts, or after nothing has read its tree for a while, can come back empty (seen once in Safari).
- **WebKit sends no notification for some page changes:** a page renaming itself, or changing its URL without a load (`history.pushState`, going back across one, a fragment change). Not to the page, its window or the app, though the page element's URL and title update at once. A load does notify (`AXLoadComplete`), with a new page element. Seen in WKWebView (the end-to-end test's app) with `--watch-ax` ([diagnostics.md](diagnostics.md#the-watch-tool)), 2026-11-26. Chrome and Firefox not checked yet.
- **Electron answers Accessibility calls in its main process,** not in the page's renderer (inferred). This fits Claude's search taking as long while it streams a reply as when it's idle.

## Limitations

- **Some page changes are recorded up to 5 s late** in WebKit apps ([Background](#background)). When a page renames itself or changes its URL without a load (`history.pushState`), nothing triggers a sample unless the window title changes too or the user's input does: a click, or keyboard focus moving (a keystroke alone doesn't). The change then waits for the next poll, so a view left within 5 s can go unrecorded.
- **Web areas nested inside a page aren't searched,** so pages in iframes or `<webview>`s aren't recorded on their own: the browser pane inside a Claude Code session, VS Code's webviews (Release Notes). Their time stays on the outer page.
- **A window whose only page is `about:blank` records no page,** even if it shows real content. Claude's ⌘-click windows render a conversation into an `about:blank` page, so they have only the window title, the conversation's name, and no conversation URL ([electron-and-claude.md](../notes/electron-and-claude.md#known-gaps)). Pinned by a test (fixture `claude-cmd-click-window.json`).
- **Apps whose page says nothing get the probe result yes anyway.** Obsidian shows the same `app://obsidian.md/index.html` for every note; Zoom shows its own UI over `https`. Harmless (a constant URL), but every sample searches for nothing. The user can choose off for them.
- **An app that shows a web page once** (a sign-in window, a "What's new" panel) gets the probe result yes for good. A probe result of no also lasts until a re-probe, even if an update adds web views.
- **Probing an Electron app switches its tree on for the rest of its run,** even if the probe result turns out no. VS Code then shows its screen reader prompt; choosing off for VS Code before its first probe avoids it.
- **Probing reads pages in apps that used to have only window titles recorded** (password managers, banking apps, Mail). URLs are scrubbed, but there are no exclusions yet.
- **The first search after a tree is switched on can find nothing,** since the tree is built lazily. For a probe, that only means waiting for the next one; with the mode on, it's a short interval without a page.
- **A re-probe requested in the future** (the clock went back after the request) keeps the app probing until the clock passes it, since every probe result is older than the request.
- **Scripts share their interpreter's choice and probe result.** An unbundled program is identified by its executable, which for a script is the interpreter (`/usr/bin/python3`), so all scripts it runs are one app here.
