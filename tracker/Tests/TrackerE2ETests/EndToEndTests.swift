import AppKit
import Foundation
import Testing
@testable import TrackerCore

/// The real tracker (the build copy, which holds the Accessibility permission) recording into a
/// temporary database, with its poll turned off, while the test drives three copies of
/// `E2ETarget`, then a throwaway Google Chrome, then a throwaway Firefox; then the rows are
/// checked against what each step showed. Takes over the screen for about 2 minutes.
///
/// Run by scripts/e2e.sh, which builds the apps, makes the run folder, and cleans up after a
/// crash. Skipped otherwise. Environment:
/// - `TIMETRACKER_E2E_TRACKER`: the tracker app to run;
/// - `TIMETRACKER_E2E_APPS`: folder holding the three target apps;
/// - `TIMETRACKER_E2E_RUN`: an empty folder for this run (database, pages, command files), where
///   the test leaves `checked` once it has checked the run;
/// - `TIMETRACKER_E2E_CHROME`: the Chrome app to drive. Empty or not set: Chrome's steps are skipped.
/// - `TIMETRACKER_E2E_FIREFOX`: the Firefox app to drive. Empty or not set: Firefox's steps are
///   skipped.
@Suite(.serialized, .enabled(if: E2E.isEnabled, "run by scripts/e2e.sh"))
struct EndToEndTests {
    @Test func recordsWhatIsOnScreen() async throws {
        let run = try E2E.Run()
        try await run.perform {
            try await Self.steps(run)
        }
        try run.check()
    }

    /// Steps that change nothing ask the tracker for a sample (`sampleNow`) before they count:
    /// otherwise they'd pass without the tracker having looked. Proven to work by "page renames
    /// itself", which nothing else would record (the poll is turned off).
    private static func steps(_ run: E2E.Run) async throws {
        let r = run.id
        let a = run.a
        let b = run.b
        let c = run.c
        let pages = run.pages

        try await run.step("plain window", expect: .init(a, window: "Plain \(r)")) {
            try await a.send("openWindow", ["id": "plain", "title": "Plain \(r)"])
        }
        try await run.step("web window", expect: .init(a, window: "Web \(r)", url: pages.one, page: "One \(r)")) {
            try await a.send("openWindow", ["id": "web", "title": "Web \(r)", "pages": [pages.one]])
        }
        try await run.step("navigate", expect: .init(a, window: "Web \(r)", url: pages.two, page: "Two \(r)")) {
            try await a.send("navigate", ["id": "web", "url": pages.two])
        }
        // WebKit sends no event for this (docs/page-reading.md#limitations), so only the sample
        // asked for records it.
        try await run.step("page renames itself", expect: .init(a, window: "Web \(r)", url: pages.two, page: "Two retitled \(r)")) {
            try await a.send("eval", ["id": "web", "js": "document.title = \(E2E.jsString("Two retitled \(r)"))"])
            try await a.waitUntil(window: "web", "document.title === \(E2E.jsString("Two retitled \(r)"))", "the title didn't change")
            run.sampleNow()
        }
        // The fragment isn't recorded (docs/url-scrubbing.md), so nothing changes.
        try await run.step("hash change", expect: .init(a, window: "Web \(r)", url: pages.two, page: "Two retitled \(r)")) {
            try await a.send("eval", ["id": "web", "js": "location.hash = 'part'"])
            try await a.waitUntil(window: "web", "location.hash === '#part'", "the hash didn't change")
            run.sampleNow()
        }
        try await run.step(
            "secret in URL",
            expect: .init(a, window: "Web \(r)", url: pages.secretScrubbed, page: "Secret \(r)")
        ) {
            try await a.send("navigate", ["id": "web", "url": pages.secret])
        }
        try await run.step(
            "window renamed",
            expect: .init(a, window: "Web renamed \(r)", url: pages.secretScrubbed, page: "Secret \(r)")
        ) {
            try await a.send("setTitle", ["id": "web", "title": "Web renamed \(r)"])
        }
        try await run.step("other window", expect: .init(a, window: "Plain \(r)")) {
            try await a.send("focusWindow", ["id": "plain"])
        }
        try await run.step("other app", expect: .init(b, window: "Bee \(r)", url: pages.bee, page: "Bee page \(r)")) {
            try await run.activate(b)
        }
        try await run.step("back", expect: .init(a, window: "Plain \(r)")) {
            try await run.activate(a)
        }
        // Two pages and focus in neither: no page is recorded (can't tell which one is being read).
        try await run.step("split, no focus", expect: .init(a, window: "Split \(r)")) {
            try await a.send("openWindow", ["id": "split", "title": "Split \(r)", "pages": [pages.one, pages.two], "isFocusCleared": true])
            try await a.expectFocus(window: "split", inPage: nil, of: 2)
        }
        try await run.step("split, focus right", expect: .init(a, window: "Split \(r)", url: pages.two, page: "Two \(r)")) {
            try await a.send("focusPage", ["id": "split", "index": 1])
            try await a.expectFocus(window: "split", inPage: 1, of: 2)
        }
        try await run.step("split, focus left", expect: .init(a, window: "Split \(r)", url: pages.one, page: "One \(r)")) {
            try await a.send("focusPage", ["id": "split", "index": 0])
            try await a.expectFocus(window: "split", inPage: 0, of: 2)
        }
        try await run.step("page with iframe", expect: .init(a, window: "Frame \(r)", url: pages.frame, page: "Frame \(r)")) {
            try await a.send("openWindow", ["id": "frame", "title": "Frame \(r)", "pages": [pages.frame]])
        }
        // The iframe is part of the page: still the outer page.
        try await run.step("focus in iframe", expect: .init(a, window: "Frame \(r)", url: pages.frame, page: "Frame \(r)")) {
            try await a.send("focusPage", ["id": "frame"])
            try await a.send("eval", ["id": "frame", "js": "document.querySelector('iframe').contentDocument.getElementById('i').focus()"])
            try await a.waitUntil(
                window: "frame",
                "document.querySelector('iframe').contentDocument.activeElement?.id === 'i' && document.hasFocus()",
                "focus didn't reach the iframe's text field"
            )
            run.sampleNow()
        }
        // A page titled "Loading" that renames itself 450 ms after loading, between the tracker's
        // first look (300 ms after the load event) and its second (400 ms later). Settling must
        // hide the "Loading" state: the row is the final page, starting when the change was first
        // seen, so before the rename (`Settler`).
        try await run.step("page settles after loading", expect: .init(a, window: "Frame \(r)", url: pages.settle, page: "Loaded \(r)")) {
            try await a.send("navigate", ["id": "frame", "url": pages.settle])
            try await a.waitUntil(window: "frame", "document.title === \(E2E.jsString("Loaded \(r)"))", "the page didn't rename itself")
            guard let renamedAtMs = try await a.send("eval", ["id": "frame", "js": "window.renamedAtMs"]) as? NSNumber else {
                throw E2EError("the page didn't say when it renamed itself")
            }
            run.expectRowStart(before: renamedAtMs.int64Value)
        }
        try await run.step("plain window again", expect: .init(a, window: "Plain \(r)")) {
            try await a.send("focusWindow", ["id": "plain"])
        }
        // An app whose only page is its own UI, loaded from its bundle: not content, so no page
        // is recorded, and page reading stays undecided (checked in `Run.check`).
        try await run.step("own UI only", expect: .init(c, window: "Own \(r)")) {
            try await c.send("openWindow", ["id": "own", "title": "Own \(r)", "pages": [c.ownPage]])
            try await run.activate(c)
        }
        try await run.step("panel", expect: .init(c, window: "Panel \(r)", subrole: "AXFloatingWindow", isMainWindow: false)) {
            try await c.send("openWindow", ["id": "panel", "title": "Panel \(r)", "isPanel": true])
        }
        try await run.step("no window", expect: .noWindow(c)) {
            try await c.send("closeWindow", ["id": "panel"])
            try await c.send("closeWindow", ["id": "own"])
        }
        try await chromeSteps(run)
        try await firefoxSteps(run)
    }

    /// Chrome reports the shown tab's URL as the window's document too, so `document` is the
    /// page URL, scrubbed the same way (docs/url-scrubbing.md).
    private static func chromeSteps(_ run: E2E.Run) async throws {
        guard let chrome = run.chrome, let web = run.served else {
            print("e2e: no Chrome given (TIMETRACKER_E2E_CHROME), its steps skipped")
            return
        }
        let r = run.id
        func shows(_ title: String, _ url: String) -> E2E.Expected {
            E2E.Expected(app: chrome.app, window: title + E2E.Chrome.windowSuffix, url: url, page: title, document: url)
        }

        var first: E2E.Chrome.Tab!
        try await run.step("Chrome", expect: shows("One \(r)", web.one)) {
            first = try await chrome.launch(web.one)
            try await chrome.expectFocus(first)
        }
        try await run.step("Chrome: navigate", expect: shows("Two \(r)", web.two)) {
            try await chrome.navigate(first, web.two)
        }
        // Chrome renames the window after the tab, which the tracker hears (`AXTitleChanged`).
        try await run.step("Chrome: page renames itself", expect: shows("Two renamed \(r)", web.two)) {
            try await chrome.eval(first, "document.title = \(E2E.jsString("Two renamed \(r)"))")
            try await chrome.waitUntil(first, "document.title === \(E2E.jsString("Two renamed \(r)"))", "the title didn't change")
        }
        // A new URL without a load, with a secret: scrubbed in the page URL and the document. With
        // a title change, which is what triggers the sample: Chrome sends nothing for `pushState`
        // alone (and updates the page's URL only with the next change), so that would wait for the
        // 5 s poll (docs/page-reading.md#limitations).
        try await run.step("Chrome: pushState and title", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await chrome.eval(first, "history.pushState(null, '', \(E2E.jsString(E2E.Pages.pushedPath))); document.title = \(E2E.jsString("Pushed \(r)"))")
            try await chrome.waitUntil(first, "location.href === \(E2E.jsString(web.pushed))", "pushState didn't change the URL")
        }
        // The fragment isn't recorded, so nothing changes.
        try await run.step("Chrome: hash change", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await chrome.eval(first, "location.hash = 'part'")
            try await chrome.waitUntil(first, "location.hash === '#part'", "the hash didn't change")
            run.sampleNow()
        }
        try await run.step("Chrome: secret in URL", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.navigate(first, web.secret)
        }
        var second: E2E.Chrome.Tab!
        try await run.step("Chrome: new tab", expect: shows("Three \(r)", web.three)) {
            second = try await chrome.open(web.three)
            try await chrome.expectFocus(second)
        }
        try await run.step("Chrome: first tab", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.activate(first)
            try await chrome.expectFocus(first)
            try await chrome.waitUntil(second, "document.visibilityState === 'hidden'", "the second tab is still shown")
        }
        var window: E2E.Chrome.Tab!
        try await run.step("Chrome: new window", expect: shows("One \(r)", web.one)) {
            window = try await chrome.open(web.one, isNewWindow: true)
            try await chrome.expectFocus(window)
        }
        try await run.step("Chrome: window closed", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.close(window)
            try await chrome.expectFocus(first)
        }
        // Browsers' own pages are content too (docs/page-reading.md).
        try await run.step("Chrome: own page", expect: shows("About Version", "chrome://version/")) {
            try await chrome.navigate(first, "chrome://version/")
        }
        try await run.step("Chrome: other app", expect: .init(run.b, window: "Bee \(r)", url: run.pages.bee, page: "Bee page \(r)")) {
            try await run.activate(run.b)
        }
        try await run.step("Chrome: back", expect: shows("About Version", "chrome://version/")) {
            try await chrome.bringToFront(first)
            try await chrome.expectFocus(first)
        }
    }

    /// Like Chrome's, with what's different in Firefox: the window is titled with the page title
    /// alone and has no document; a URL change alone (`pushState`) updates the page's URL at
    /// once but sends no event the tracker listens for (only the address bar's
    /// `AXValueChanged`), so it's sampled on request; its own pages (`about:…`) can't be
    /// loaded through BiDi, so they aren't stepped through.
    private static func firefoxSteps(_ run: E2E.Run) async throws {
        guard let firefox = run.firefox, let web = run.served else {
            print("e2e: no Firefox given (TIMETRACKER_E2E_FIREFOX), its steps skipped")
            return
        }
        let r = run.id
        func shows(_ title: String, _ url: String) -> E2E.Expected {
            E2E.Expected(app: firefox.app, window: title + E2E.Firefox.windowSuffix, url: url, page: title, document: nil)
        }

        // Firefox builds its page tree only once something asks for it, so the tracker's first
        // probe, when Firefox comes to the front, may find no page. The retry 2 s later
        // (`PageReadingPolicy.probeBackoff`) finds it; until then only the window is recorded.
        var first: E2E.Firefox.Tab!
        try await run.step(
            "Firefox",
            expect: shows("One \(r)", web.one),
            mayFirstBe: E2E.Expected(app: firefox.app, window: "One \(r)" + E2E.Firefox.windowSuffix, url: nil, page: nil, document: nil),
            extraLatencyMs: PageReadingPolicy.probeBackoff.firstDelayMs
        ) {
            first = try await firefox.launch(web.one)
            try await firefox.expectFocus(first)
        }
        try await run.step("Firefox: navigate", expect: shows("Two \(r)", web.two)) {
            try await firefox.navigate(first, web.two)
        }
        // Firefox renames the window after the tab, which the tracker hears (`AXTitleChanged`).
        try await run.step("Firefox: page renames itself", expect: shows("Two renamed \(r)", web.two)) {
            try await firefox.eval(first, "document.title = \(E2E.jsString("Two renamed \(r)"))")
            try await firefox.waitUntil(first, "document.title === \(E2E.jsString("Two renamed \(r)"))", "the title didn't change")
        }
        // No event: sampled on request.
        try await run.step("Firefox: pushState alone", expect: shows("Two renamed \(r)", web.moved)) {
            try await firefox.eval(first, "history.pushState(null, '', \(E2E.jsString(E2E.Pages.movedPath)))")
            try await firefox.waitUntil(first, "location.href === \(E2E.jsString(web.moved))", "pushState didn't change the URL")
            run.sampleNow()
        }
        // With a secret, scrubbed; the title change triggers the sample.
        try await run.step("Firefox: pushState and title", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await firefox.eval(first, "history.pushState(null, '', \(E2E.jsString(E2E.Pages.pushedPath))); document.title = \(E2E.jsString("Pushed \(r)"))")
            try await firefox.waitUntil(first, "location.href === \(E2E.jsString(web.pushed))", "pushState didn't change the URL")
        }
        // The fragment isn't recorded, so nothing changes.
        try await run.step("Firefox: hash change", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await firefox.eval(first, "location.hash = 'part'")
            try await firefox.waitUntil(first, "location.hash === '#part'", "the hash didn't change")
            run.sampleNow()
        }
        try await run.step("Firefox: secret in URL", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.navigate(first, web.secret)
        }
        var second: E2E.Firefox.Tab!
        try await run.step("Firefox: new tab", expect: shows("Three \(r)", web.three)) {
            second = try await firefox.open(web.three)
            try await firefox.expectFocus(second)
        }
        try await run.step("Firefox: first tab", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.activate(first)
            try await firefox.expectFocus(first)
            try await firefox.waitUntil(second, "document.visibilityState === 'hidden'", "the second tab is still shown")
        }
        var window: E2E.Firefox.Tab!
        try await run.step("Firefox: new window", expect: shows("One \(r)", web.one)) {
            window = try await firefox.open(web.one, isNewWindow: true)
            try await firefox.expectFocus(window)
        }
        try await run.step("Firefox: window closed", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.close(window)
            try await firefox.expectFocus(first)
        }
        try await run.step("Firefox: other app", expect: .init(run.b, window: "Bee \(r)", url: run.pages.bee, page: "Bee page \(r)")) {
            try await run.activate(run.b)
        }
        try await run.step("Firefox: back", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.bringToFront()
            try await firefox.expectFocus(first)
        }
    }
}

enum E2E {
    static let environment = ProcessInfo.processInfo.environment
    /// Set and not empty. Further checks in `Run.init`, which fail the test instead of
    /// skipping it; scripts/e2e.sh fails a run that was skipped.
    static let isEnabled = ["TIMETRACKER_E2E_TRACKER", "TIMETRACKER_E2E_APPS", "TIMETRACKER_E2E_RUN"].allSatisfy { !(environment[$0] ?? "").isEmpty }

    /// Each step is held this long before the next one.
    static let holdMs: Int64 = 2500
    /// A change may be recorded this long after the step that made it is done: an event, plus
    /// settling, plus slack.
    static let latencyMs: Int64 = 1500
    /// The tracker's poll, turned off in effect: a change that's recorded only by the poll
    /// would otherwise pass about 1 time in 4 (when the poll lands in the 1.5 s after a step).
    static let trackerPollSeconds = 3600

    static let targetIds = ["com.raquo.timetracker.e2e-target-a", "com.raquo.timetracker.e2e-target-b", "com.raquo.timetracker.e2e-target-c"]

    /// An app as the tracker records it (`tracker_app`): bundle ID, install path, name.
    struct App: Equatable {
        let bundleId: String
        let path: String
        let name: String
    }

    /// What a step should be recorded as: every column but input idle, which depends on when
    /// someone last touched the mouse or keyboard (see `Run.check`). Rows must also not be
    /// screen-locked.
    struct Expected: Equatable, CustomStringConvertible {
        var app: App
        var window: String?
        var url: String?
        var page: String?
        /// The window's document (`AXDocument`): none in the test app's windows.
        var document: String?
        var role: String?
        var subrole: String?
        var isMainWindow: Int64?
        var isFullScreen: Int64?

        /// A window of the test app: by default a standard main window.
        init(_ target: Target, window: String, url: String? = nil, page: String? = nil, subrole: String = "AXStandardWindow", isMainWindow: Bool = true) {
            self.init(app: target.app, window: window, url: url, page: page, document: nil, subrole: subrole, isMainWindow: isMainWindow)
        }

        /// A window that's not full screen.
        init(app: App, window: String, url: String?, page: String?, document: String?, subrole: String = "AXStandardWindow", isMainWindow: Bool = true) {
            self.app = app
            self.window = window
            self.url = url
            self.page = page
            self.document = document
            role = "AXWindow"
            self.subrole = subrole
            self.isMainWindow = isMainWindow ? 1 : 0
            isFullScreen = 0
        }

        /// Nothing but the app.
        fileprivate init(app: App) {
            self.app = app
        }

        /// The app in front with no window: nothing about a window is recorded.
        static func noWindow(_ target: Target) -> Expected {
            Expected(app: target.app)
        }

        var description: String {
            let window = window.map { "\($0) (\(role ?? "-")/\(subrole ?? "-"), main \(isMainWindow.map(String.init) ?? "-"), full screen \(isFullScreen.map(String.init) ?? "-"))" } ?? "no window"
            return "\(app.bundleId) | \(window) | \(url ?? "no URL") | \(page ?? "no page title") | \(document.map { "document \($0)" } ?? "no document")"
        }
    }

    struct Step {
        let name: String
        let expected: Expected
        /// Its commands sent; done (the last one answered, its checks passed); next step sent.
        let sentMs: Int64
        let doneMs: Int64
        var endMs: Int64
        /// Its row must start before this (`Run.expectRowStart(before:)`).
        let rowStartsBeforeMs: Int64?
        /// A state the tracker may record first, during a changeover that's longer by
        /// `extraLatencyMs` (`Run.step`).
        let mayFirstBe: Expected?
        let extraLatencyMs: Int64

        /// From when its rows must match `expected`.
        var checkedFromMs: Int64 {
            doneMs + E2E.latencyMs + extraLatencyMs
        }
    }

    struct Row: CustomStringConvertible {
        let startMs: Int64
        let endMs: Int64
        let app: String?
        let appPath: String?
        let appName: String?
        let window: String?
        let url: String?
        let page: String?
        let document: String?
        let role: String?
        let subrole: String?
        let isMainWindow: Int64?
        let isFullScreen: Int64?
        let isInputIdle: Int64
        let isScreenLocked: Int64

        var asExpected: Expected? {
            guard let app else {
                return nil
            }
            var e = Expected(app: App(bundleId: app, path: appPath ?? "", name: appName ?? ""))
            e.window = window
            e.url = url
            e.page = page
            e.document = document
            e.role = role
            e.subrole = subrole
            e.isMainWindow = isMainWindow
            e.isFullScreen = isFullScreen
            return e
        }

        /// Everything recorded: two rows in a row with the same are a split for nothing.
        var content: String {
            "\(asExpected?.description ?? "no app") | \(appPath ?? "no path") | \(appName ?? "no name") | idle \(isInputIdle) | locked \(isScreenLocked)"
        }

        var description: String {
            asExpected?.description ?? "no app\(isScreenLocked != 0 ? " (screen locked)" : "")"
        }
    }

    /// The test's HTML pages under one base URL (the pages folder, or the page server serving
    /// it), as loaded and as the tracker should record them. `write` makes the files.
    struct Pages {
        let one: String
        let two: String
        let three: String
        let bee: String
        let frame: String
        /// Titled "Loading …" until 450 ms after it has loaded, then "Loaded …".
        let settle: String
        let secret: String
        let secretScrubbed: String
        /// Where `pushState` goes (relative, from `two`), absolute, and as recorded. No such
        /// file: the page only pretends to be there.
        static let pushedPath = "pushed.html?session=abc&q=ok"
        let pushed: String
        let pushedScrubbed: String
        /// Where `pushState` goes without a new title (relative, from `two`), and absolute. No
        /// such file either.
        static let movedPath = "moved.html?q=ok"
        let moved: String

        /// `base` ends with a slash.
        init(base: String) {
            one = base + "one.html"
            two = base + "two.html"
            three = base + "three.html"
            bee = base + "bee.html"
            frame = base + "frame.html"
            settle = base + "settle.html"
            secret = base + "secret.html?token=hunter2&q=ok#part"
            secretScrubbed = base + "secret.html?token=REDACTED&q=ok"
            pushed = base + Self.pushedPath
            pushedScrubbed = base + "pushed.html?session=REDACTED&q=ok"
            moved = base + Self.movedPath
        }

        /// Writes the files `init` names into `dir`. Titles carry the run ID.
        static func write(to dir: URL, runId: String) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            func page(_ name: String, _ title: String, _ body: String = "") throws {
                let html = "<!doctype html><title>\(title)</title><body><h1>\(title)</h1>\(body)</body>"
                try html.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try page("one.html", "One \(runId)")
            try page("two.html", "Two \(runId)")
            try page("three.html", "Three \(runId)")
            try page("bee.html", "Bee page \(runId)")
            // srcdoc: same origin as the outer page, so its script can move focus into the iframe
            // (a script can't focus into another origin's frame without a click; each file:// page
            // is its own origin).
            try page("frame.html", "Frame \(runId)", "<iframe srcdoc=\"<input id=i>\" width=600 height=200></iframe>")
            try page("settle.html", "Loading \(runId)", """
                <script>
                addEventListener('load', () => setTimeout(() => {
                    window.renamedAtMs = Date.now();
                    document.title = \(E2E.jsString("Loaded \(runId)"));
                }, 450));
                </script>
                """)
            try page("secret.html", "Secret \(runId)")
        }
    }

    /// A running copy of `E2ETarget`, driven through its command files.
    final class Target {
        let bundleId: String
        let bundleUrl: URL
        /// As in its Info.plist (scripts/e2e.sh), which is what the tracker records.
        let name: String
        let controlDir: URL
        var pid: pid_t?
        private var next = 1

        init(bundleId: String, bundleUrl: URL, name: String, controlDir: URL) {
            self.bundleId = bundleId
            self.bundleUrl = bundleUrl
            self.name = name
            self.controlDir = controlDir
        }

        var app: App {
            App(bundleId: bundleId, path: bundleUrl.path, name: name)
        }

        /// A page inside the app's bundle (scripts/e2e.sh puts it there): its own UI, not content.
        var ownPage: String {
            bundleUrl.appendingPathComponent("Contents/Resources/own.html").absoluteString
        }

        /// Returns the command's result (`eval`'s), nil if none. Throws `ScriptError` for a
        /// script that threw.
        @discardableResult
        func send(_ op: String, _ fields: [String: Any] = [:]) async throws -> Any? {
            let n = next
            next += 1
            var command = fields
            command["op"] = op
            let data = try JSONSerialization.data(withJSONObject: command)
            try data.write(to: controlDir.appendingPathComponent("cmd-\(n).json"), options: .atomic)
            let ack = controlDir.appendingPathComponent("ack-\(n).json")
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let data = try? Data(contentsOf: ack) {
                    let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if let error = body?["scriptError"] as? String {
                        throw ScriptError(description: "\(bundleId) \(op): \(error)")
                    }
                    if let error = body?["error"] as? String {
                        throw E2EError("\(bundleId) \(op): \(error)")
                    }
                    let result = body?["result"]
                    return result is NSNull ? nil : result
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw E2EError("\(bundleId) \(op): no answer in 10 s")
        }

        /// Waits up to 2 s for `js`, run in the page of `window`, to be true. A script that
        /// throws (e.g. before the page has what it looks for) counts as false, like in Chrome.
        func waitUntil(window: String, index: Int = 0, _ js: String, _ failure: String) async throws {
            let deadline = Date().addingTimeInterval(2)
            while true {
                let isTrue: Bool
                do {
                    isTrue = try await send("eval", ["id": window, "index": index, "js": js]) as? Bool == true
                }
                catch is ScriptError {
                    isTrue = false
                }
                if isTrue {
                    return
                }
                guard Date() < deadline else {
                    throw E2EError("\(bundleId): \(failure)")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        /// Checks that keyboard focus is in page `inPage` of `window`'s `count` pages (nil: in none).
        func expectFocus(window: String, inPage: Int?, of count: Int) async throws {
            for index in 0..<count {
                let isFocused = index == inPage
                try await waitUntil(
                    window: window,
                    index: index,
                    "document.hasFocus() === \(isFocused)",
                    "page \(index) of \(window) should\(isFocused ? "" : "n't") have focus"
                )
            }
        }
    }

    final class Run {
        let id: String
        let dir: URL
        let apps: URL
        let pages: Pages
        let tracker: URL
        let a: Target
        let b: Target
        /// Shows only its own UI (a page from its bundle), never content.
        let c: Target
        let chrome: Chrome?
        let firefox: Firefox?
        /// The pages over HTTP, once the server runs (with a browser only).
        private(set) var served: Pages?
        var steps: [Step] = []
        private var server: PageServer?
        private var trackerPid: pid_t?
        /// The app in front before the run, to bring back afterwards.
        private var previousFront: (pid: pid_t, bundleUrl: URL)?
        /// When the tracker was sent SIGTERM, and when it had exited.
        private var stopSentMs: Int64?
        private var stopDoneMs: Int64?
        /// Set by the step in progress (`expectRowStart(before:)`).
        private var rowStartsBeforeMs: Int64?

        var databasePath: String {
            dir.appendingPathComponent("tracker.db").path
        }

        /// Fails unless every app given exists and the run folder exists and is empty: an old
        /// database or browser profile in it would make the checks see a previous run.
        init() throws {
            id = String(UUID().uuidString.prefix(6))
            func folder(_ variable: String, isEmpty: Bool = false) throws -> URL {
                let path = E2E.environment[variable] ?? ""
                var isDirectory: ObjCBool = false
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw E2EError("\(variable)=\(path): not a folder")
                }
                if isEmpty, try !FileManager.default.contentsOfDirectory(atPath: path).isEmpty {
                    throw E2EError("\(variable)=\(path): not empty")
                }
                return URL(fileURLWithPath: path)
            }
            tracker = try folder("TIMETRACKER_E2E_TRACKER")
            let dir = try folder("TIMETRACKER_E2E_RUN", isEmpty: true)
            let apps = try folder("TIMETRACKER_E2E_APPS")
            self.dir = dir
            self.apps = apps
            let pagesDir = dir.appendingPathComponent("pages", isDirectory: true)
            try Pages.write(to: pagesDir, runId: id)
            pages = Pages(base: pagesDir.absoluteString)
            func target(_ letter: String, _ bundleId: String) throws -> Target {
                let control = dir.appendingPathComponent("control-\(letter)")
                try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
                let name = "E2E Target \(letter.uppercased())"
                let bundle = apps.appendingPathComponent("\(name).app")
                guard FileManager.default.fileExists(atPath: bundle.path) else {
                    throw E2EError("no \(bundle.path)")
                }
                return Target(bundleId: bundleId, bundleUrl: bundle, name: name, controlDir: control)
            }
            a = try target("a", E2E.targetIds[0])
            b = try target("b", E2E.targetIds[1])
            c = try target("c", E2E.targetIds[2])
            if let path = E2E.environment["TIMETRACKER_E2E_CHROME"], !path.isEmpty {
                chrome = try Chrome(appUrl: try folder("TIMETRACKER_E2E_CHROME"), profile: dir.appendingPathComponent("chrome-profile"))
            }
            else {
                chrome = nil
            }
            if let path = E2E.environment["TIMETRACKER_E2E_FIREFOX"], !path.isEmpty {
                firefox = try Firefox(appUrl: try folder("TIMETRACKER_E2E_FIREFOX"), profile: dir.appendingPathComponent("firefox-profile"))
            }
            else {
                firefox = nil
            }
        }

        /// Starts the tracker and the target apps, runs `body`, stops the tracker. Cleans up
        /// either way.
        func perform(_ body: () async throws -> Void) async throws {
            do {
                try await start()
                try await body()
                try await stopTracker()
            }
            catch {
                await cleanUp()
                throw error
            }
            await cleanUp()
        }

        private func start() async throws {
            previousFront = try E2E.frontmostApp()
            if chrome != nil || firefox != nil {
                let server = try PageServer(dir: dir.appendingPathComponent("pages"))
                try await server.start()
                self.server = server
                served = Pages(base: server.base + "/")
            }

            let tracker = NSWorkspace.OpenConfiguration()
            tracker.createsNewApplicationInstance = true
            tracker.activates = false
            tracker.environment = ["TIMETRACKER_DB": databasePath, "TIMETRACKER_POLL_SECONDS": String(E2E.trackerPollSeconds)]
            trackerPid = try await NSWorkspace.shared.openApplication(at: self.tracker, configuration: tracker).processIdentifier

            for target in [a, b, c] {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.activates = false
                config.arguments = ["--control", target.controlDir.path]
                target.pid = try await NSWorkspace.shared.openApplication(at: target.bundleUrl, configuration: config).processIdentifier
            }
            try await b.send("openWindow", ["id": "bee", "title": "Bee \(id)", "pages": [pages.bee]])
            try await activate(a)
            // Until the tracker has recorded A in front (no window yet), so the first step starts from
            // a recorded state: a change seen before it would move the first row's start earlier.
            let deadline = Date().addingTimeInterval(10)
            let sql = "SELECT count(*) FROM tracker_interval i JOIN tracker_app a ON a.id = i.app_id WHERE a.identifier = ?"
            // Only once the tracker has made the database: opening it would create it.
            while !FileManager.default.fileExists(atPath: databasePath) || (try? Database(path: databasePath).query(sql, [.text(a.bundleId)]).first?.first?.int) ?? 0 == 0 {
                guard Date() < deadline else {
                    throw E2EError("the tracker didn't record \(a.bundleId) in 10 s (see its log: log show --predicate 'subsystem == \"com.raquo.timetracker\"' --last 2m)")
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        /// Runs `action` (its commands, and checks that they took effect), then holds for
        /// `holdMs` plus `extraLatencyMs`. The step lasts from when `action` started until the
        /// next one does. For a change the tracker is known to see late: `mayFirstBe` is a state
        /// it may record before `expected`, within `latencyMs` plus `extraLatencyMs` of the step
        /// being done.
        func step(_ name: String, expect expected: Expected, mayFirstBe: Expected? = nil, extraLatencyMs: Int64 = 0, _ action: () async throws -> Void) async throws {
            let sentMs = nowMs()
            if !steps.isEmpty {
                steps[steps.count - 1].endMs = sentMs
            }
            rowStartsBeforeMs = nil
            try await action()
            let doneMs = nowMs()
            steps.append(Step(name: name, expected: expected, sentMs: sentMs, doneMs: doneMs, endMs: doneMs + E2E.holdMs + extraLatencyMs, rowStartsBeforeMs: rowStartsBeforeMs, mayFirstBe: mayFirstBe, extraLatencyMs: extraLatencyMs))
            // Longer by the longer changeover, so as much of the step is checked as in others.
            try await Task.sleep(for: .milliseconds(E2E.holdMs + extraLatencyMs))
        }

        /// Asks the tracker for a sample now (SIGUSR1), for a step whose change sends no event
        /// or that changes nothing. The poll is turned off (`trackerPollSeconds`).
        func sampleNow() {
            if let trackerPid {
                kill(trackerPid, SIGUSR1)
            }
        }

        /// The step in progress: its row must start before `ms`, e.g. before a change that
        /// settling should have backdated it over.
        func expectRowStart(before ms: Int64) {
            rowStartsBeforeMs = ms
        }

        /// Brings `target` to the front, as clicking its Dock icon would.
        func activate(_ target: Target) async throws {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: target.bundleUrl, configuration: config)
            let deadline = Date().addingTimeInterval(5)
            while try E2E.frontmostPid() != target.pid {
                guard Date() < deadline else {
                    throw E2EError("\(target.bundleId) didn't come to the front")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        /// SIGTERM: the tracker closes its open row and exits.
        private func stopTracker() async throws {
            if !steps.isEmpty {
                steps[steps.count - 1].endMs = nowMs()
            }
            guard let pid = trackerPid else {
                return
            }
            stopSentMs = nowMs()
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while kill(pid, 0) == 0 {
                guard Date() < deadline else {
                    throw E2EError("the tracker didn't exit after SIGTERM")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            stopDoneMs = nowMs()
            trackerPid = nil
        }

        /// Kills what we started and brings back the app that was in front. The run folder is
        /// left to scripts/e2e.sh.
        private func cleanUp() async {
            for pid in [trackerPid, a.pid, b.pid, c.pid].compactMap({ $0 }) {
                kill(pid, SIGKILL)
            }
            trackerPid = nil
            a.pid = nil
            b.pid = nil
            c.pid = nil
            // Before bringing back the app in front: if that's the user's Chrome or Firefox, opening
            // it while the test's is still quitting could reach the test's instead.
            await chrome?.quit()
            await firefox?.quit()
            server?.stop()
            server = nil
            // Only if it's still running: opening an app that has quit would launch it again.
            if let previousFront, kill(previousFront.pid, 0) == 0 {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: previousFront.bundleUrl, configuration: config)
            }
        }

        func rows() throws -> [Row] {
            let columns = [
                "i.start_ms", "i.end_ms", "a.identifier", "a.app_path", "a.name", "t.title", "u.url", "pt.title", "d.path",
                "r.role", "r.subrole", "i.is_main_window", "i.is_full_screen", "i.is_input_idle", "i.is_screen_locked",
            ]
            let db = try Database(path: databasePath)
            return try db.query("""
                SELECT \(columns.joined(separator: ", "))
                FROM tracker_interval i
                LEFT JOIN tracker_app a ON a.id = i.app_id
                LEFT JOIN tracker_title t ON t.id = i.title_id
                LEFT JOIN tracker_url u ON u.id = i.page_url_id
                LEFT JOIN tracker_title pt ON pt.id = i.page_title_id
                LEFT JOIN tracker_path d ON d.id = i.document_path_id
                LEFT JOIN tracker_window_role r ON r.id = i.window_role_id
                ORDER BY i.start_ms
                """).map { values in
                func v(_ column: String) -> SqlValue {
                    values[columns.firstIndex(of: column)!]
                }
                return Row(
                    startMs: v("i.start_ms").int ?? 0, endMs: v("i.end_ms").int ?? 0,
                    app: v("a.identifier").text, appPath: v("a.app_path").text, appName: v("a.name").text,
                    window: v("t.title").text, url: v("u.url").text, page: v("pt.title").text, document: v("d.path").text,
                    role: v("r.role").text, subrole: v("r.subrole").text,
                    isMainWindow: v("i.is_main_window").int, isFullScreen: v("i.is_full_screen").int,
                    isInputIdle: v("i.is_input_idle").int ?? -1, isScreenLocked: v("i.is_screen_locked").int ?? -1
                )
            }
        }

        /// What the tracker decided about each app's pages (`tracker_app_page_probe`), by bundle ID.
        func pageProbes() throws -> [String: (hasContentPages: Int64?, decidedAtMs: Int64?, probeCount: Int64)] {
            let db = try Database(path: databasePath)
            var probes: [String: (hasContentPages: Int64?, decidedAtMs: Int64?, probeCount: Int64)] = [:]
            for c in try db.query("SELECT identifier, has_content_pages, decided_at_ms, probe_count FROM tracker_app_page_probe WHERE identifier_type = 0") {
                if let id = c[0].text {
                    probes[id] = (c[1].int, c[2].int, c[3].int ?? 0)
                }
            }
            return probes
        }

        /// Per step:
        /// - from `latencyMs` after it was done until the next one, every row matches what it
        ///   showed;
        /// - before that (the changeover), any row that starts is already the step's: the row
        ///   in progress may go on (the previous state, checked by the previous step), but
        ///   nothing in between, such as a page half loaded or an old title with the new URL.
        ///   Except a step's `mayFirstBe`, in its longer changeover;
        /// - the first step doesn't find its row started before it (the tracker had recorded the
        ///   state before, `start`). For a later step that would mean a missed change, which
        ///   already fails the step before: its own state isn't what was recorded;
        /// - a step that set `expectRowStart(before:)` finds its row started before then.
        ///
        /// Over the run: rows don't overlap or leave gaps, no two rows in a row record the same
        /// (a split for nothing), and the last row ends when the tracker was stopped. Each app
        /// that showed a page had page reading decided on (`tracker_app_page_probe`) at its first
        /// step with one; each app that never did was probed but not decided.
        ///
        /// Last, leaves `checked` in the run folder for scripts/e2e.sh.
        ///
        /// Input idle isn't checked: the test makes no input, so once a minute has passed since
        /// the last real input the run goes idle (and back, if someone moves the mouse).
        /// That changes only the idle flag: going idle moves a row's start back to the last
        /// input, but never before the start of the row in progress (`Recorder`), so contents
        /// and boundaries stay as they were.
        func check() throws {
            let rows = try rows()
            let origin = steps.first?.sentMs ?? 0
            func t(_ ms: Int64) -> String {
                String(format: "%6.2f", Double(ms - origin) / 1000)
            }
            print("e2e: rows (seconds from the first step):")
            for row in rows where row.endMs >= origin {
                print("  \(t(row.startMs))–\(t(row.endMs))  \(row)")
            }
            print("e2e: steps (sent–done, then held until the next):")
            for step in steps {
                print("  \(t(step.sentMs))–\(t(step.doneMs))–\(t(step.endMs))  \(step.name): \(step.expected)")
            }

            for (i, step) in steps.enumerated() {
                let checkedFrom = step.checkedFromMs
                let during = rows.filter { $0.endMs > checkedFrom && $0.startMs < step.endMs }
                if during.isEmpty {
                    Issue.record("\(step.name): no row")
                    continue
                }
                for row in during where row.asExpected != step.expected || row.isScreenLocked != 0 {
                    Issue.record("\(step.name) at \(t(max(row.startMs, checkedFrom))): expected \(step.expected), got \(row)")
                }
                for row in rows where row.startMs >= step.sentMs && row.startMs < checkedFrom && row.endMs <= checkedFrom {
                    let isAllowed = row.asExpected == step.expected || (step.mayFirstBe != nil && row.asExpected == step.mayFirstBe)
                    if !isAllowed || row.isScreenLocked != 0 {
                        Issue.record("\(step.name): passing row at \(t(row.startMs))–\(t(row.endMs)) during the changeover: \(row)")
                    }
                }
                if let before = step.rowStartsBeforeMs, let first = during.first, first.startMs >= before {
                    Issue.record("\(step.name): its row starts at \(t(first.startMs)), expected before \(t(before))")
                }
                if i == 0, let first = during.first, first.asExpected == step.expected, first.startMs < step.sentMs {
                    Issue.record("\(step.name): its row started at \(t(first.startMs)), before the step (\(t(step.sentMs)))")
                }
            }

            // Hints for failures that would otherwise show only as every step failing.
            let stepRows = rows.filter { $0.endMs > origin }
            if !stepRows.isEmpty, stepRows.allSatisfy({ $0.window == nil }) {
                Issue.record("no window titles at all: does \(E2E.environment["TIMETRACKER_E2E_TRACKER"] ?? "the tracker") have the Accessibility permission?")
            }
            if stepRows.contains(where: { $0.isInputIdle != 0 }) {
                print("e2e: (for information) the run went input idle: a minute without input")
            }

            let runRows = rows.filter { $0.endMs > origin && $0.startMs < (steps.last?.endMs ?? 0) }
            for (prev, next) in zip(runRows, runRows.dropFirst()) {
                if next.startMs != prev.endMs {
                    Issue.record("rows at \(t(prev.endMs)) and \(t(next.startMs)): \(next.startMs < prev.endMs ? "overlap" : "gap")")
                }
                else if next.content == prev.content {
                    Issue.record("rows at \(t(prev.startMs)) and \(t(next.startMs)) record the same: \(next.content)")
                }
            }
            // SIGTERM closes the row in progress then (`Tracker`), not at its last sample.
            if let last = rows.last, let stopSentMs, let stopDoneMs {
                if last.endMs < stopSentMs || last.endMs > stopDoneMs {
                    Issue.record("the last row ends at \(t(last.endMs)), not when the tracker was stopped (\(t(stopSentMs))–\(t(stopDoneMs)))")
                }
            }

            // Apps that showed a page: decided yes at their first step with one. Apps that never
            // did: probed (it showed a window), but not decided.
            let probes = try pageProbes()
            for app in Set(steps.map(\.expected.app.bundleId)).sorted() {
                guard let probe = probes[app] else {
                    Issue.record("\(app): no page probe row")
                    continue
                }
                if probe.probeCount < 1 {
                    Issue.record("\(app): probe_count \(probe.probeCount)")
                }
                guard let step = steps.first(where: { $0.expected.app.bundleId == app && $0.expected.url != nil }) else {
                    if probe.hasContentPages != nil || probe.decidedAtMs != nil {
                        Issue.record("\(app) never showed a content page, but page reading was decided: has_content_pages \(probe.hasContentPages.map(String.init) ?? "nil")")
                    }
                    continue
                }
                if probe.hasContentPages != 1 {
                    Issue.record("\(app): has_content_pages \(probe.hasContentPages.map(String.init) ?? "nil"), expected 1")
                }
                if let decided = probe.decidedAtMs, decided < step.sentMs || decided > step.checkedFromMs {
                    Issue.record("\(app): page reading decided at \(t(decided)), not during \"\(step.name)\", its first step with a page (\(t(step.sentMs))–\(t(step.checkedFromMs)))")
                }
            }

            // For scripts/e2e.sh: `swift test` passes a skipped test too.
            func ran(_ app: App?) -> Int {
                steps.contains { $0.expected.app == app } ? 1 : 0
            }
            let note = "steps=\(steps.count)\nchrome=\(ran(chrome?.app))\nfirefox=\(ran(firefox?.app))\n"
            try note.write(to: dir.appendingPathComponent("checked"), atomically: true, encoding: .utf8)
        }
    }

    /// From LaunchServices, not `NSWorkspace.frontmostApplication`, which only updates while
    /// this process's main run loop runs.
    static func frontmostPid() throws -> pid_t? {
        let asn = try shell("/usr/bin/lsappinfo", ["front"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try shell("/usr/bin/lsappinfo", ["info", "-only", "pid", asn])
        // "pid"=1234
        return info.split(separator: "=").last.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func frontmostApp() throws -> (pid: pid_t, bundleUrl: URL)? {
        guard let pid = try frontmostPid(), let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
            return nil
        }
        return (pid, url)
    }

    static func shell(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct E2EError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
