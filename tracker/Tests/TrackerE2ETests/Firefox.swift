import AppKit
import Foundation

extension E2E {
    /// A second Firefox with a throwaway profile in the run folder (`-profile … -no-remote
    /// -new-instance`), beside the user's own, driven through WebDriver BiDi
    /// (`--remote-debugging-port`): tabs, windows, navigations and page scripts, never clicks or
    /// keystrokes. Same bundle ID as the user's Firefox, so it's told apart by pid.
    final class Firefox: Browser {
        static let name = "Firefox"
        /// Firefox titles the window with the page's title alone, no app name (seen in Firefox
        /// Developer Edition 162).
        static let windowSuffix = ""

        let appUrl: URL
        /// From its Info.plist, as the tracker records it.
        let app: App
        let profile: URL
        var pid: pid_t?
        private var socket: BrowserSocket?

        /// A tab: its top-level browsing context.
        struct Tab {
            let context: String
        }

        init(appUrl: URL, profile: URL) throws {
            self.appUrl = appUrl
            self.profile = profile
            app = try App(bundleAt: appUrl)
        }

        /// Starts Firefox in the background, loads `url` in a new tab and closes the one it
        /// started with, then brings Firefox to the front. In that order so the tracker's first
        /// look at Firefox (its first page probe) sees a loaded page.
        ///
        /// A new tab rather than the first one: a tab opened through BiDi has keyboard focus in
        /// its page, while the first one (started on `about:blank`) keeps it in the address bar,
        /// and Firefox gives it back there whenever that tab is shown again.
        func launch(_ url: String) async throws -> Tab {
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            // Firefox also sets its recommended automation prefs once BiDi runs (no updates, no
            // first-run pages); these cover the time before, and what they leave out.
            let prefs = [
                "browser.shell.checkDefaultBrowser": "false",
                "browser.startup.homepage_override.mstone": "\"ignore\"",
                "browser.aboutwelcome.enabled": "false",
                "datareporting.policy.dataSubmissionEnabled": "false",
                "toolkit.telemetry.reportingpolicy.firstRun": "false",
                "app.update.disabledForTesting": "true",
                "browser.tabs.warnOnClose": "false",
                "browser.sessionstore.resume_from_crash": "false",
            ]
            let userJs = prefs.sorted { $0.key < $1.key }.map { "user_pref(\"\($0.key)\", \($0.value));\n" }.joined()
            try userJs.write(to: profile.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)

            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = false
            config.arguments = ["-profile", profile.path, "-no-remote", "-new-instance", "--remote-debugging-port=0", "about:blank"]
            pid = try await NSWorkspace.shared.openApplication(at: appUrl, configuration: config).processIdentifier

            // Firefox writes its port once BiDi listens: {"ws_host": …, "ws_port": …}.
            let portFile = profile.appendingPathComponent("WebDriverBiDiServer.json")
            let deadline = Date().addingTimeInterval(15)
            var port: Int?
            while port == nil {
                guard Date() < deadline else {
                    throw E2EError("Firefox didn't open WebDriver BiDi in 15 s")
                }
                try await Task.sleep(for: .milliseconds(100))
                if let data = try? Data(contentsOf: portFile), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    port = body["ws_port"] as? Int
                }
            }
            // One session per Firefox, and it outlives its connection: this one lasts the run.
            while true {
                let socket = try BrowserSocket(url: URL(string: "ws://127.0.0.1:\(port!)/session")!, name: "Firefox")
                do {
                    _ = try await socket.send("session.new", ["capabilities": [:] as [String: Any]])
                    self.socket = socket
                    break
                }
                catch {
                    socket.close()
                    guard Date() < deadline else {
                        throw E2EError("Firefox: no BiDi session: \(error)")
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
            }

            let first = try await contexts()
            let tab = try await open(url)
            for context in first {
                try await close(Tab(context: context))
            }
            try await bringToFront()
            return tab
        }

        /// Loads `url` in the tab; returns once it has loaded.
        func navigate(_ tab: Tab, _ url: String) async throws {
            try await send("browsingContext.navigate", ["context": tab.context, "url": url, "wait": "complete"])
            try await waitUntilLoaded(tab, url)
        }

        /// Opens `url` in a new tab of the focused window (or a new window), shown in front.
        /// BiDi opens it on `about:blank` first: Firefox shows that for a few ms (window titled
        /// with the app's name, no page), short enough for settling to hide.
        func open(_ url: String, isNewWindow: Bool = false) async throws -> Tab {
            let created = try await send("browsingContext.create", ["type": isNewWindow ? "window" : "tab"])
            guard let context = created["context"] as? String else {
                throw E2EError("Firefox: no tab for \(url)")
            }
            let tab = Tab(context: context)
            try await navigate(tab, url)
            return tab
        }

        /// Shows the tab in its window, as clicking it in the tab strip would.
        func activate(_ tab: Tab) async throws {
            try await send("browsingContext.activate", ["context": tab.context])
        }

        func close(_ tab: Tab) async throws {
            try await send("browsingContext.close", ["context": tab.context])
        }

        /// Brings Firefox to the front, as clicking its Dock icon would, and waits until it's in
        /// front. By pid, since the user's Firefox has the same bundle (BiDi has no command for
        /// it: `browsingContext.activate` focuses the window but leaves the app behind).
        func bringToFront() async throws {
            guard let pid, let app = NSRunningApplication(processIdentifier: pid) else {
                throw E2EError("Firefox isn't running")
            }
            app.activate(options: [])
            try await E2E.waitUntilInFront(pid, "Firefox")
        }

        /// The script's value (booleans, numbers, strings; nil for anything else); throws
        /// `ScriptError` if it threw.
        @discardableResult
        func eval(_ tab: Tab, _ js: String) async throws -> Any? {
            let result = try await send("script.evaluate", [
                "expression": js, "target": ["context": tab.context], "awaitPromise": false, "resultOwnership": "none",
            ])
            if result["type"] as? String == "exception" {
                let details = result["exceptionDetails"] as? [String: Any]
                throw ScriptError(description: "Firefox: \(js): \(details?["text"] as? String ?? "exception")")
            }
            return (result["result"] as? [String: Any])?["value"]
        }

        /// Asks Firefox to quit (`browser.close`), so it takes its helper processes down itself,
        /// then makes sure it and they are gone (`E2E.finishQuit`).
        func quit() async {
            if pid != nil {
                socket?.post("browser.close")
            }
            await E2E.finishQuit(pid, profile: profile)
            pid = nil
            socket?.close()
            socket = nil
        }

        /// The top-level browsing contexts (tabs), in every window.
        private func contexts() async throws -> [String] {
            let tree = try await send("browsingContext.getTree", ["maxDepth": 0])
            return (tree["contexts"] as? [[String: Any]] ?? []).compactMap { $0["context"] as? String }
        }

        @discardableResult
        private func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            guard let socket else {
                throw E2EError("Firefox isn't running")
            }
            return try await socket.send(method, params)
        }
    }
}
