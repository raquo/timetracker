import AppKit
import Foundation

extension E2E {
    /// A second Google Chrome with a throwaway profile in the run folder, beside the user's own,
    /// driven through DevTools (`--remote-debugging-port`): tabs, windows, navigations and page
    /// scripts, never clicks or keystrokes. Same bundle ID as the user's Chrome, so it's told
    /// apart by pid.
    final class Chrome: Browser {
        static let name = "Chrome"
        static let windowSuffix = " - Google Chrome"

        let appUrl: URL
        /// From its Info.plist, as the tracker records it.
        let app: App
        let profile: URL
        var pid: pid_t?
        private var devTools: BrowserSocket?

        /// A tab, and the DevTools session attached to it.
        struct Tab {
            let targetId: String
            let session: String
        }

        init(appUrl: URL, profile: URL) throws {
            self.appUrl = appUrl
            self.profile = profile
            app = try App(bundleAt: appUrl)
        }

        /// Starts Chrome in the background on `url`, waits for the page to load, then brings it
        /// to the front. In that order so the tracker's first look at Chrome (its first page
        /// probe) sees a loaded page.
        func launch(_ url: String) async throws -> Tab {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = false
            config.arguments = [
                "--user-data-dir=\(profile.path)",
                "--remote-debugging-port=0",
                // No first-run tabs, prompts or sign-in; no keychain (the user's "Chrome Safe
                // Storage" stays untouched); no background requests to Google.
                "--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen",
                "--disable-sync", "--use-mock-keychain", "--disable-background-networking",
                "--disable-component-update",
                url,
            ]
            pid = try await NSWorkspace.shared.openApplication(at: appUrl, configuration: config).processIdentifier

            // Chrome writes its port, and the browser endpoint's path, once DevTools listens.
            let portFile = profile.appendingPathComponent("DevToolsActivePort")
            let deadline = Date().addingTimeInterval(15)
            var lines: [Substring] = []
            while lines.count < 2 {
                guard Date() < deadline else {
                    throw E2EError("Chrome didn't open DevTools in 15 s")
                }
                try await Task.sleep(for: .milliseconds(100))
                lines = ((try? String(contentsOf: portFile, encoding: .utf8)) ?? "").split(separator: "\n")
            }
            let devTools = try BrowserSocket(url: URL(string: "ws://127.0.0.1:\(lines[0])\(lines[1])")!, name: "DevTools")
            self.devTools = devTools

            var targetId: String?
            while targetId == nil {
                guard Date() < deadline else {
                    throw E2EError("Chrome opened no tab for \(url)")
                }
                let targets = try await send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
                targetId = targets.first { $0["type"] as? String == "page" }?["targetId"] as? String
                if targetId == nil {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let tab = try await attach(targetId!)
            try await waitUntilLoaded(tab, url)
            try await bringToFront(tab)
            return tab
        }

        /// Loads `url` in the tab; returns once it has loaded.
        func navigate(_ tab: Tab, _ url: String) async throws {
            try await send("Page.navigate", ["url": url], tab)
            try await waitUntilLoaded(tab, url)
        }

        /// Opens `url` in a new tab of the focused window (or a new window), shown in front.
        func open(_ url: String, isNewWindow: Bool = false) async throws -> Tab {
            let created = try await send("Target.createTarget", ["url": url, "newWindow": isNewWindow])
            guard let targetId = created["targetId"] as? String else {
                throw E2EError("Chrome: no tab for \(url)")
            }
            let tab = try await attach(targetId)
            try await waitUntilLoaded(tab, url)
            return tab
        }

        /// Shows the tab in its window, as clicking it in the tab strip would.
        func activate(_ tab: Tab) async throws {
            try await send("Target.activateTarget", ["targetId": tab.targetId])
        }

        func close(_ tab: Tab) async throws {
            try await send("Target.closeTarget", ["targetId": tab.targetId])
        }

        /// Brings Chrome to the front with this tab shown, and waits until it's in front.
        func bringToFront(_ tab: Tab) async throws {
            try await send("Page.bringToFront", [:], tab)
            try await E2E.waitUntilInFront(pid, "Chrome")
        }

        /// The script's value; throws `ScriptError` if it threw.
        @discardableResult
        func eval(_ tab: Tab, _ js: String) async throws -> Any? {
            let result = try await send("Runtime.evaluate", ["expression": js, "returnByValue": true], tab)
            if let exception = result["exceptionDetails"] as? [String: Any] {
                let description = (exception["exception"] as? [String: Any])?["description"] as? String
                throw ScriptError(description: "Chrome: \(js): \(description ?? exception["text"] as? String ?? "exception")")
            }
            return (result["result"] as? [String: Any])?["value"]
        }

        /// Asks Chrome to quit (`Browser.close`), so it takes its helper processes down itself,
        /// then makes sure it and they are gone (`E2E.finishQuit`).
        func quit() async {
            if pid != nil {
                devTools?.post("Browser.close")
            }
            await E2E.finishQuit(pid, profile: profile)
            pid = nil
            devTools?.close()
            devTools = nil
        }

        private func attach(_ targetId: String) async throws -> Tab {
            let attached = try await send("Target.attachToTarget", ["targetId": targetId, "flatten": true])
            guard let session = attached["sessionId"] as? String else {
                throw E2EError("Chrome: couldn't attach to tab \(targetId)")
            }
            return Tab(targetId: targetId, session: session)
        }

        @discardableResult
        private func send(_ method: String, _ params: [String: Any] = [:], _ tab: Tab? = nil) async throws -> [String: Any] {
            guard let devTools else {
                throw E2EError("Chrome isn't running")
            }
            return try await devTools.send(method, params, session: tab?.session)
        }
    }
}
