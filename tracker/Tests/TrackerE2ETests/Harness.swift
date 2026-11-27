import AppKit
import Foundation
import Testing
@testable import TrackerCore

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
        var pid: pid_t?
        private let commands: CommandFiles

        init(bundleId: String, bundleUrl: URL, name: String, controlDir: URL) {
            self.bundleId = bundleId
            self.bundleUrl = bundleUrl
            self.name = name
            commands = CommandFiles(dir: controlDir, name: bundleId)
        }

        var controlDir: URL {
            commands.dir
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
            try await commands.send(op, fields)
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
        let helper: Helper
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
        /// Seconds since the last real input when the tracker was stopped: its last sample sees
        /// the run go input idle at 60 (`Sampler.idleThresholdSeconds`).
        private var inputIdleAtStopSeconds: Double?
        /// Set by the step in progress (`expectRowStart(before:)`).
        private var rowStartsBeforeMs: Int64?

        var databasePath: String {
            dir.appendingPathComponent("tracker.db").path
        }

        /// Makes the test's folder in the run folder, named after the test (`chrome()`: `chrome`).
        /// Fails unless every app given exists and the run folder has no folder for this test
        /// yet: an old database or browser profile in it would make the checks see a previous run.
        init() throws {
            id = String(UUID().uuidString.prefix(6))
            func folder(_ variable: String) throws -> URL {
                let path = E2E.environment[variable] ?? ""
                var isDirectory: ObjCBool = false
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw E2EError("\(variable)=\(path): not a folder")
                }
                return URL(fileURLWithPath: path)
            }
            tracker = try folder("TIMETRACKER_E2E_TRACKER")
            guard let testName = Test.current?.name.replacingOccurrences(of: "()", with: "") else {
                throw E2EError("not run by a test")
            }
            let dir = try folder("TIMETRACKER_E2E_RUN").appendingPathComponent(testName, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: dir.path) else {
                throw E2EError("\(dir.path) exists already")
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
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
            let helperControl = dir.appendingPathComponent("control-helper")
            try FileManager.default.createDirectory(at: helperControl, withIntermediateDirectories: true)
            helper = Helper(bundleUrl: try folder("TIMETRACKER_E2E_HELPER"), controlDir: helperControl)
            // Empty skips the browser's test; not set at all means the script's environment didn't
            // reach the test, which must fail rather than skip.
            func browser(_ variable: String) throws -> URL? {
                guard let path = E2E.environment[variable] else {
                    throw E2EError("\(variable) not set (set but empty skips the test that needs it)")
                }
                return path.isEmpty ? nil : try folder(variable)
            }
            chrome = try browser("TIMETRACKER_E2E_CHROME").map { try Chrome(appUrl: $0, profile: dir.appendingPathComponent("chrome-profile")) }
            firefox = try browser("TIMETRACKER_E2E_FIREFOX").map { try Firefox(appUrl: $0, profile: dir.appendingPathComponent("firefox-profile")) }
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
            // First: without the permission, a step that needs it would fail only minutes in.
            try await helper.start()
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
        /// being done. `expected` is read once `action` is done, so it can use what the action
        /// found out (e.g. a URL only known once the page has loaded).
        func step(_ name: String, expect expected: @autoclosure () -> Expected, mayFirstBe: Expected? = nil, extraLatencyMs: Int64 = 0, _ action: () async throws -> Void) async throws {
            let sentMs = nowMs()
            if !steps.isEmpty {
                steps[steps.count - 1].endMs = sentMs
            }
            rowStartsBeforeMs = nil
            do {
                try await action()
            }
            catch {
                throw E2EError("step \"\(name)\": \(error)")
            }
            let doneMs = nowMs()
            steps.append(Step(name: name, expected: expected(), sentMs: sentMs, doneMs: doneMs, endMs: doneMs + E2E.holdMs + extraLatencyMs, rowStartsBeforeMs: rowStartsBeforeMs, mayFirstBe: mayFirstBe, extraLatencyMs: extraLatencyMs))
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
            inputIdleAtStopSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
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
            for pid in [trackerPid, a.pid, b.pid, c.pid, helper.pid].compactMap({ $0 }) {
                kill(pid, SIGKILL)
            }
            trackerPid = nil
            a.pid = nil
            b.pid = nil
            c.pid = nil
            helper.pid = nil
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
        /// Last, leaves `checked` in the test's folder for scripts/e2e.sh (`noteChecked`).
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
                    let idle = inputIdleAtStopSeconds.map { String(format: "; no input for %.1f s then", $0) } ?? ""
                    Issue.record("the last row ends at \(t(last.endMs)), not when the tracker was stopped (\(t(stopSentMs))–\(t(stopDoneMs))\(idle))")
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

            try noteChecked("\(steps.count) steps")
        }

        /// For scripts/e2e.sh: `swift test` passes a skipped test too, so each test leaves a
        /// note once it has checked its run, or chosen to skip it.
        func noteChecked(_ note: String) throws {
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
