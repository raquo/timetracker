import AppKit
import Foundation
import Network

extension E2E {
    /// A second Google Chrome with a throwaway profile in the run folder, beside the user's own,
    /// driven through DevTools (`--remote-debugging-port`): tabs, windows, navigations and page
    /// scripts, never clicks or keystrokes. Same bundle ID as the user's Chrome, so it's told
    /// apart by pid.
    final class Chrome {
        static let windowSuffix = " - Google Chrome"

        let appUrl: URL
        /// From its Info.plist, as the tracker records it.
        let app: App
        let profile: URL
        var pid: pid_t?
        private var devTools: DevTools?

        /// A tab, and the DevTools session attached to it.
        struct Tab {
            let targetId: String
            let session: String
        }

        init(appUrl: URL, profile: URL) throws {
            guard let bundle = Bundle(url: appUrl), let bundleId = bundle.bundleIdentifier else {
                throw E2EError("\(appUrl.path) isn't an app")
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? bundle.object(forInfoDictionaryKey: "CFBundleName")
            self.appUrl = appUrl
            self.profile = profile
            app = App(bundleId: bundleId, path: appUrl.path, name: name as? String ?? "")
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
            let devTools = try DevTools(url: URL(string: "ws://127.0.0.1:\(lines[0])\(lines[1])")!)
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
            let deadline = Date().addingTimeInterval(5)
            while try E2E.frontmostPid() != pid {
                guard Date() < deadline else {
                    throw E2EError("Chrome didn't come to the front")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        /// The script's value; throws if it threw.
        @discardableResult
        func eval(_ tab: Tab, _ js: String) async throws -> Any? {
            let result = try await send("Runtime.evaluate", ["expression": js, "returnByValue": true], tab)
            if let exception = result["exceptionDetails"] as? [String: Any] {
                let description = (exception["exception"] as? [String: Any])?["description"] as? String
                throw E2EError("Chrome: \(js): \(description ?? exception["text"] as? String ?? "exception")")
            }
            return (result["result"] as? [String: Any])?["value"]
        }

        /// Waits up to 5 s for `js` to be true in the tab. A script that fails (the page is
        /// between documents) counts as false.
        func waitUntil(_ tab: Tab, _ js: String, _ failure: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            while true {
                let isTrue: Bool
                do {
                    isTrue = try await eval(tab, js) as? Bool == true
                }
                catch {
                    isTrue = false
                }
                if isTrue {
                    return
                }
                guard Date() < deadline else {
                    throw E2EError("Chrome: \(failure)")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        /// Checks the step's premise: this tab is the one shown, in the window that has keyboard
        /// focus, with Chrome in front.
        func expectFocus(_ tab: Tab) async throws {
            guard try E2E.frontmostPid() == pid else {
                throw E2EError("Chrome isn't in front")
            }
            try await waitUntil(tab, "document.visibilityState === 'visible' && document.hasFocus()", "the tab isn't the one shown with focus")
        }

        func kill() {
            if let pid {
                Darwin.kill(pid, SIGKILL)
            }
            pid = nil
            devTools?.close()
            devTools = nil
            // Its helper processes name the profile in their arguments.
            _ = try? E2E.shell("/usr/bin/pkill", ["-f", profile.path])
        }

        private func waitUntilLoaded(_ tab: Tab, _ url: String) async throws {
            try await waitUntil(tab, "document.readyState === 'complete' && location.href === \(jsString(url))", "\(url) didn't load")
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

    /// A JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// The Chrome DevTools Protocol over a WebSocket: commands and their answers. Events are
    /// ignored.
    final class DevTools: @unchecked Sendable {
        private let task: URLSessionWebSocketTask
        private let lock = NSLock()
        private var next = 1
        private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]

        init(url: URL) throws {
            task = URLSession.shared.webSocketTask(with: url)
            task.maximumMessageSize = 64 << 20
            task.resume()
            receive()
        }

        /// Fails after 10 s without an answer.
        func send(_ method: String, _ params: [String: Any], session: String?) async throws -> [String: Any] {
            let id = nextId()
            var message: [String: Any] = ["id": id, "method": method, "params": params]
            if let session {
                message["sessionId"] = session
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                waiting[id] = continuation
                lock.unlock()
                task.send(.string(text)) { [self] error in
                    if let error {
                        finish(id, .failure(error))
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
                    finish(id, .failure(E2EError("DevTools \(method): no answer in 10 s")))
                }
            }
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }

        private func nextId() -> Int {
            lock.lock()
            defer {
                lock.unlock()
            }
            let id = next
            next += 1
            return id
        }

        private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
            lock.lock()
            let continuation = waiting.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(with: result)
        }

        private func receive() {
            task.receive { [weak self] result in
                guard let self else {
                    return
                }
                switch result {
                case .failure(let error):
                    lock.lock()
                    let all = waiting
                    waiting = [:]
                    lock.unlock()
                    for continuation in all.values {
                        continuation.resume(throwing: error)
                    }
                case .success(let message):
                    if case .string(let text) = message,
                       let body = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                       let id = body["id"] as? Int {
                        if let error = body["error"] as? [String: Any] {
                            finish(id, .failure(E2EError("DevTools: \(error["message"] as? String ?? "\(error)")")))
                        }
                        else {
                            finish(id, .success(body["result"] as? [String: Any] ?? [:]))
                        }
                    }
                    receive()
                }
            }
        }
    }

    /// Serves the run's pages over HTTP on 127.0.0.1, for Chrome: some of what a page does
    /// (`history.pushState`) isn't allowed on `file://` pages.
    final class PageServer: @unchecked Sendable {
        let dir: URL
        private let listener: NWListener
        private let queue = DispatchQueue(label: "e2e.page-server")
        private(set) var base = ""
        /// Until the listener is ready or has failed. Touched on `queue` only.
        private var whenReady: CheckedContinuation<UInt16, Error>?

        init(dir: URL) throws {
            self.dir = dir
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        func start() async throws {
            listener.newConnectionHandler = { [self] connection in
                serve(connection)
            }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    whenReady?.resume(returning: listener.port?.rawValue ?? 0)
                    whenReady = nil
                case .failed(let error):
                    whenReady?.resume(throwing: error)
                    whenReady = nil
                default:
                    break
                }
            }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    whenReady = continuation
                    listener.start(queue: queue)
                }
            }
            base = "http://127.0.0.1:\(port)"
        }

        func stop() {
            listener.cancel()
        }

        /// GET /<file>: that file from the pages folder, else 404. One request per connection.
        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [self] data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let name = String(target.split(separator: "?").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let file = dir.appendingPathComponent(name)
                let body = !name.isEmpty && !name.contains("/") ? (try? Data(contentsOf: file)) : nil
                var response = Data()
                if let body {
                    response.append(Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8))
                    response.append(body)
                }
                else {
                    response.append(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                }
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
}
