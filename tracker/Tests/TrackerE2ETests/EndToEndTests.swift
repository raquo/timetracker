import AppKit
import Foundation
import Testing
@testable import TrackerCore

/// The real tracker (the build copy, which holds the Accessibility permission) recording into a
/// temporary database while the test drives two copies of `E2ETarget`; then the rows are
/// checked against what each step showed. Takes over the screen for about 45 s.
///
/// Run by scripts/e2e.sh, which builds the apps, makes the run folder, and cleans up after a
/// crash. Skipped otherwise. Environment:
/// - `TIMETRACKER_E2E_TRACKER`: the tracker app to run;
/// - `TIMETRACKER_E2E_APPS`: folder holding the two target apps;
/// - `TIMETRACKER_E2E_RUN`: an empty folder for this run (database, pages, command files).
@Suite(.serialized, .enabled(if: E2E.isEnabled, "run by scripts/e2e.sh"))
struct EndToEndTests {
    @Test func recordsWhatIsOnScreen() async throws {
        let run = try E2E.Run()
        try await run.perform {
            try await Self.steps(run)
        }
        try run.check()
    }

    private static func steps(_ run: E2E.Run) async throws {
        let r = run.id
        let a = run.a
        let b = run.b
        let pages = run.pages

        try await run.step("plain window", expect: .init(app: a, window: "Plain \(r)")) {
            try await a.send("openWindow", ["id": "plain", "title": "Plain \(r)"])
        }
        try await run.step("web window", expect: .init(app: a, window: "Web \(r)", url: pages.one, page: "One \(r)")) {
            try await a.send("openWindow", ["id": "web", "title": "Web \(r)", "pages": [pages.one]])
        }
        try await run.step("navigate", expect: .init(app: a, window: "Web \(r)", url: pages.two, page: "Two \(r)")) {
            try await a.send("navigate", ["id": "web", "url": pages.two])
        }
        // The fragment isn't recorded (docs/url-scrubbing.md), so nothing changes. Not tested: the
        // page renaming itself or changing its URL without a load (`history.pushState`). WebKit
        // sends no event for those, so they're recorded at the next 5 s poll, which a 2.5 s step
        // can't wait for (docs/page-reading.md#limitations).
        try await run.step("hash change", expect: .init(app: a, window: "Web \(r)", url: pages.two, page: "Two \(r)")) {
            try await a.send("eval", ["id": "web", "js": "location.hash = 'part'"])
            try await a.waitUntil(window: "web", "location.hash === '#part'", "the hash didn't change")
        }
        try await run.step(
            "secret in URL",
            expect: .init(app: a, window: "Web \(r)", url: pages.secretScrubbed, page: "Secret \(r)")
        ) {
            try await a.send("navigate", ["id": "web", "url": pages.secret])
        }
        try await run.step(
            "window renamed",
            expect: .init(app: a, window: "Web renamed \(r)", url: pages.secretScrubbed, page: "Secret \(r)")
        ) {
            try await a.send("setTitle", ["id": "web", "title": "Web renamed \(r)"])
        }
        try await run.step("other window", expect: .init(app: a, window: "Plain \(r)")) {
            try await a.send("focusWindow", ["id": "plain"])
        }
        try await run.step("other app", expect: .init(app: b, window: "Bee \(r)", url: pages.bee, page: "Bee page \(r)")) {
            try await run.activate(b)
        }
        try await run.step("back", expect: .init(app: a, window: "Plain \(r)")) {
            try await run.activate(a)
        }
        // Two pages and focus in neither: no page is recorded (can't tell which one is being read).
        try await run.step("split, no focus", expect: .init(app: a, window: "Split \(r)")) {
            try await a.send("openWindow", ["id": "split", "title": "Split \(r)", "pages": [pages.one, pages.two], "isFocusCleared": true])
            try await a.expectFocus(window: "split", inPage: nil, of: 2)
        }
        try await run.step("split, focus right", expect: .init(app: a, window: "Split \(r)", url: pages.two, page: "Two \(r)")) {
            try await a.send("focusPage", ["id": "split", "index": 1])
            try await a.expectFocus(window: "split", inPage: 1, of: 2)
        }
        try await run.step("split, focus left", expect: .init(app: a, window: "Split \(r)", url: pages.one, page: "One \(r)")) {
            try await a.send("focusPage", ["id": "split", "index": 0])
            try await a.expectFocus(window: "split", inPage: 0, of: 2)
        }
        try await run.step("page with iframe", expect: .init(app: a, window: "Frame \(r)", url: pages.frame, page: "Frame \(r)")) {
            try await a.send("openWindow", ["id": "frame", "title": "Frame \(r)", "pages": [pages.frame]])
        }
        // The iframe is part of the page: still the outer page.
        try await run.step("focus in iframe", expect: .init(app: a, window: "Frame \(r)", url: pages.frame, page: "Frame \(r)")) {
            try await a.send("focusPage", ["id": "frame"])
            try await a.send("eval", ["id": "frame", "js": "document.querySelector('iframe').contentDocument.getElementById('i').focus()"])
            try await a.waitUntil(
                window: "frame",
                "document.querySelector('iframe').contentDocument.activeElement?.id === 'i' && document.hasFocus()",
                "focus didn't reach the iframe's text field"
            )
        }
        try await run.step("plain window again", expect: .init(app: a, window: "Plain \(r)")) {
            try await a.send("focusWindow", ["id": "plain"])
        }
    }
}

enum E2E {
    static let environment = ProcessInfo.processInfo.environment
    static let isEnabled = environment["TIMETRACKER_E2E_TRACKER"] != nil && environment["TIMETRACKER_E2E_APPS"] != nil && environment["TIMETRACKER_E2E_RUN"] != nil

    /// Each step is held this long before the next one.
    static let holdMs: Int64 = 2500
    /// A change may be recorded this long after the step that made it is done: an event, plus
    /// settling, plus slack.
    static let latencyMs: Int64 = 1500

    static let targetIds = ["com.raquo.timetracker.e2e-target-a", "com.raquo.timetracker.e2e-target-b"]

    /// What a step should be recorded as. Everything else is checked too: a standard main
    /// window, no document, not locked. Except input idle, which depends on when someone last
    /// touched the mouse or keyboard (see `Run.check`).
    struct Expected: Equatable, CustomStringConvertible {
        var app: String
        var window: String
        var url: String? = nil
        var page: String? = nil

        init(app: Target, window: String, url: String? = nil, page: String? = nil) {
            self.init(bundleId: app.bundleId, window: window, url: url, page: page)
        }

        init(bundleId: String, window: String, url: String?, page: String?) {
            self.app = bundleId
            self.window = window
            self.url = url
            self.page = page
        }

        var description: String {
            "\(app) | \(window) | \(url ?? "no URL") | \(page ?? "no page title")"
        }
    }

    struct Step {
        let name: String
        let expected: Expected
        /// Its commands sent; done (the last one answered, its checks passed); next step sent.
        let sentMs: Int64
        let doneMs: Int64
        var endMs: Int64
    }

    struct Row: CustomStringConvertible {
        let startMs: Int64
        let endMs: Int64
        let app: String?
        let window: String?
        let url: String?
        let page: String?
        let document: String?
        let role: String?
        let subrole: String?
        let isMainWindow: Int64?
        let isInputIdle: Int64
        let isScreenLocked: Int64

        var asExpected: Expected? {
            guard let app, let window else {
                return nil
            }
            return Expected(bundleId: app, window: window, url: url, page: page)
        }

        /// What else must hold for every row of a step.
        var problems: [String] {
            var p: [String] = []
            if role != "AXWindow" || subrole != "AXStandardWindow" {
                p.append("window role \(role ?? "nil") / \(subrole ?? "nil")")
            }
            if isMainWindow != 1 {
                p.append("is_main_window \(isMainWindow.map(String.init) ?? "nil")")
            }
            if document != nil {
                p.append("document \(document!)")
            }
            if isScreenLocked != 0 {
                p.append("screen locked")
            }
            return p
        }

        var description: String {
            "\(app ?? "no app") | \(window ?? "no title") | \(url ?? "no URL") | \(page ?? "no page title")"
        }
    }

    /// The test's HTML pages, as the URLs the tracker should record.
    struct Pages {
        let one: String
        let two: String
        let secret: String
        let secretScrubbed: String
        let bee: String
        let frame: String

        init(dir: URL, runId: String) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            func page(_ name: String, _ title: String, _ body: String = "") throws -> String {
                let html = "<!doctype html><title>\(title)</title><body><h1>\(title)</h1>\(body)</body>"
                let file = dir.appendingPathComponent(name)
                try html.write(to: file, atomically: true, encoding: .utf8)
                return file.absoluteString
            }
            one = try page("one.html", "One \(runId)")
            two = try page("two.html", "Two \(runId)")
            let secretPage = try page("secret.html", "Secret \(runId)")
            secret = secretPage + "?token=hunter2&q=ok#part"
            secretScrubbed = secretPage + "?token=REDACTED&q=ok"
            bee = try page("bee.html", "Bee page \(runId)")
            // srcdoc: same origin as the outer page, so its script can move focus into the iframe
            // (a script can't focus into another origin's frame without a click; each file:// page
            // is its own origin).
            frame = try page("frame.html", "Frame \(runId)", "<iframe srcdoc=\"<input id=i>\" width=600 height=200></iframe>")
        }
    }

    /// A running copy of `E2ETarget`, driven through its command files.
    final class Target {
        let bundleId: String
        let bundleUrl: URL?
        let controlDir: URL?
        var pid: pid_t?
        private var next = 1

        init(bundleId: String, bundleUrl: URL? = nil, controlDir: URL? = nil) {
            self.bundleId = bundleId
            self.bundleUrl = bundleUrl
            self.controlDir = controlDir
        }

        /// Returns the command's result (`eval`'s), nil if none.
        @discardableResult
        func send(_ op: String, _ fields: [String: Any] = [:]) async throws -> Any? {
            guard let controlDir else {
                throw E2EError("\(bundleId) isn't driven")
            }
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

        /// Waits up to 2 s for `js`, run in the page of `window`, to be true.
        func waitUntil(window: String, index: Int = 0, _ js: String, _ failure: String) async throws {
            let deadline = Date().addingTimeInterval(2)
            while try await send("eval", ["id": window, "index": index, "js": js]) as? Bool != true {
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
        let a: Target
        let b: Target
        var steps: [Step] = []
        private var trackerPid: pid_t?
        private var previousFront: URL?

        var databasePath: String {
            dir.appendingPathComponent("tracker.db").path
        }

        init() throws {
            id = String(UUID().uuidString.prefix(6))
            dir = URL(fileURLWithPath: E2E.environment["TIMETRACKER_E2E_RUN"]!)
            apps = URL(fileURLWithPath: E2E.environment["TIMETRACKER_E2E_APPS"]!)
            pages = try Pages(dir: dir.appendingPathComponent("pages"), runId: id)
            let dir = dir
            let apps = apps
            func target(_ letter: String, _ bundleId: String) throws -> Target {
                let control = dir.appendingPathComponent("control-\(letter)")
                try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
                return Target(bundleId: bundleId, bundleUrl: apps.appendingPathComponent("E2E Target \(letter.uppercased()).app"), controlDir: control)
            }
            a = try target("a", E2E.targetIds[0])
            b = try target("b", E2E.targetIds[1])
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
            previousFront = try E2E.frontmostBundleUrl()

            let tracker = NSWorkspace.OpenConfiguration()
            tracker.createsNewApplicationInstance = true
            tracker.activates = false
            tracker.environment = ["TIMETRACKER_DB": databasePath]
            trackerPid = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: E2E.environment["TIMETRACKER_E2E_TRACKER"]!), configuration: tracker).processIdentifier

            for target in [a, b] {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.activates = false
                config.arguments = ["--control", target.controlDir!.path]
                target.pid = try await NSWorkspace.shared.openApplication(at: target.bundleUrl!, configuration: config).processIdentifier
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
        /// `holdMs`. The step lasts from when `action` started until the next one does.
        func step(_ name: String, expect expected: Expected, _ action: () async throws -> Void) async throws {
            let sentMs = nowMs()
            if !steps.isEmpty {
                steps[steps.count - 1].endMs = sentMs
            }
            try await action()
            let doneMs = nowMs()
            steps.append(Step(name: name, expected: expected, sentMs: sentMs, doneMs: doneMs, endMs: doneMs + E2E.holdMs))
            try await Task.sleep(for: .milliseconds(E2E.holdMs))
        }

        /// Brings `target` to the front, as clicking its Dock icon would.
        func activate(_ target: Target) async throws {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: target.bundleUrl!, configuration: config)
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
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while kill(pid, 0) == 0 {
                guard Date() < deadline else {
                    throw E2EError("the tracker didn't exit after SIGTERM")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            trackerPid = nil
        }

        /// Kills what we started and brings back the app that was in front. The run folder is
        /// left to scripts/e2e.sh.
        private func cleanUp() async {
            for pid in [trackerPid, a.pid, b.pid].compactMap({ $0 }) {
                kill(pid, SIGKILL)
            }
            trackerPid = nil
            a.pid = nil
            b.pid = nil
            if let previousFront {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: previousFront, configuration: config)
            }
        }

        func rows() throws -> [Row] {
            let db = try Database(path: databasePath)
            return try db.query("""
                SELECT i.start_ms, i.end_ms, a.identifier, t.title, u.url, pt.title, d.path, r.role, r.subrole,
                       i.is_main_window, i.is_input_idle, i.is_screen_locked
                FROM tracker_interval i
                LEFT JOIN tracker_app a ON a.id = i.app_id
                LEFT JOIN tracker_title t ON t.id = i.title_id
                LEFT JOIN tracker_url u ON u.id = i.page_url_id
                LEFT JOIN tracker_title pt ON pt.id = i.page_title_id
                LEFT JOIN tracker_path d ON d.id = i.document_path_id
                LEFT JOIN tracker_window_role r ON r.id = i.window_role_id
                ORDER BY i.start_ms
                """).map { c in
                Row(
                    startMs: c[0].int ?? 0, endMs: c[1].int ?? 0, app: c[2].text, window: c[3].text, url: c[4].text,
                    page: c[5].text, document: c[6].text, role: c[7].text, subrole: c[8].text,
                    isMainWindow: c[9].int, isInputIdle: c[10].int ?? -1, isScreenLocked: c[11].int ?? -1
                )
            }
        }

        /// Per step: from `latencyMs` after it was done until the next one, every row matches
        /// what it showed, and its row didn't start before it was sent. Rows during the run
        /// don't overlap or leave gaps.
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
                print("  \(t(row.startMs))–\(t(row.endMs))  \(row)\(row.problems.isEmpty ? "" : "  [\(row.problems.joined(separator: ", "))]")")
            }
            print("e2e: steps:")
            for step in steps {
                print("  \(t(step.sentMs))–\(t(step.endMs))  \(step.name): \(step.expected)")
            }

            for (i, step) in steps.enumerated() {
                let checkedFrom = step.doneMs + E2E.latencyMs
                let during = rows.filter { $0.endMs > checkedFrom && $0.startMs < step.endMs }
                if during.isEmpty {
                    Issue.record("\(step.name): no row")
                    continue
                }
                for row in during {
                    if row.asExpected != step.expected {
                        Issue.record("\(step.name) at \(t(max(row.startMs, checkedFrom))): expected \(step.expected), got \(row)")
                    }
                    else if !row.problems.isEmpty {
                        Issue.record("\(step.name): \(row.problems.joined(separator: ", "))")
                    }
                }
                let isChange = i == 0 || steps[i - 1].expected != step.expected
                if isChange, let first = during.first, first.asExpected == step.expected, first.startMs < step.sentMs {
                    // A row started earlier says the change was missed, or recorded too early.
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
            }
        }
    }

    static func nowMsValue() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// From LaunchServices, not `NSWorkspace.frontmostApplication`, which only updates while
    /// this process's main run loop runs.
    static func frontmostPid() throws -> pid_t? {
        let asn = try shell("/usr/bin/lsappinfo", ["front"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try shell("/usr/bin/lsappinfo", ["info", "-only", "pid", asn])
        // "pid"=1234
        return info.split(separator: "=").last.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func frontmostBundleUrl() throws -> URL? {
        guard let pid = try frontmostPid(), let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return app.bundleURL
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

private func nowMs() -> Int64 {
    E2E.nowMsValue()
}

struct E2EError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
