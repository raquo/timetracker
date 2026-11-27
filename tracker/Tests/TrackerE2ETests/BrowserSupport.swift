import AppKit
import Foundation
import Network

/// What the browsers' drivers share: waiting on page scripts, the WebSocket protocol, the page
/// server, stopping a browser and its helpers.
extension E2E {
    /// A throwaway browser the test drives (`Chrome`, `Firefox`): what the shared waits need.
    protocol Browser: AnyObject {
        associatedtype Tab
        /// Names the browser in errors.
        static var name: String { get }
        var pid: pid_t? { get }
        /// The script's value; throws `ScriptError` if it threw.
        func eval(_ tab: Tab, _ js: String) async throws -> Any?
    }

    /// A JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// A script that threw (`Browser.eval`).
    struct ScriptError: Error, CustomStringConvertible {
        let description: String
    }

    /// For a browser just asked to quit: SIGKILL if it's still running after 5 s. Then any
    /// process still naming the profile in its arguments (helpers do) is stopped too: SIGTERM,
    /// then SIGKILL after 2 s.
    static func finishQuit(_ pid: pid_t?, profile: URL) async {
        if let pid {
            let deadline = Date().addingTimeInterval(5)
            while Darwin.kill(pid, 0) == 0, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if Darwin.kill(pid, 0) == 0 {
                Darwin.kill(pid, SIGKILL)
            }
        }
        _ = try? shell("/usr/bin/pkill", ["-f", profile.path])
        let deadline = Date().addingTimeInterval(2)
        while isAnyRunning(profile), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isAnyRunning(profile) {
            _ = try? shell("/usr/bin/pkill", ["-9", "-f", profile.path])
        }
    }

    private static func isAnyRunning(_ profile: URL) -> Bool {
        !((try? shell("/usr/bin/pgrep", ["-f", profile.path])) ?? "").isEmpty
    }

    /// Waits until the app with this pid is in front.
    static func waitUntilInFront(_ pid: pid_t?, _ name: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while try frontmostPid() != pid {
            guard Date() < deadline else {
                throw E2EError("\(name) didn't come to the front")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A browser's remote protocol over a WebSocket: commands and their answers. Events are
    /// ignored. Both protocols spoken here send `{id, method, params}` and answer with the same
    /// `id`: Chrome's DevTools Protocol (`result`, or an `error` object), and WebDriver BiDi in
    /// Firefox (`type` "success" with `result`, or "error" with `error` and `message`).
    final class BrowserSocket: @unchecked Sendable {
        /// The browser answered a command with an error.
        struct ProtocolError: Error, CustomStringConvertible {
            let description: String
        }

        /// Names the browser in errors.
        private let name: String

        private let task: URLSessionWebSocketTask
        private let lock = NSLock()
        private var next = 1
        private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
        /// Why the connection ended, once it has: later commands fail with it at once.
        private var closedError: Error?

        init(url: URL, name: String) throws {
            self.name = name
            task = URLSession.shared.webSocketTask(with: url)
            task.maximumMessageSize = 64 << 20
            task.resume()
            receive()
        }

        /// Fails after 10 s without an answer. `session`: Chrome's session for one tab.
        func send(_ method: String, _ params: [String: Any], session: String? = nil) async throws -> [String: Any] {
            let id = nextId()
            var message: [String: Any] = ["id": id, "method": method, "params": params]
            if let session {
                message["sessionId"] = session
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let closedError {
                    lock.unlock()
                    continuation.resume(throwing: closedError)
                    return
                }
                waiting[id] = continuation
                lock.unlock()
                task.send(.string(text)) { [self] error in
                    if let error {
                        finish(id, .failure(error))
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in
                    finish(id, .failure(E2EError("\(name) \(method): no answer in 10 s")))
                }
            }
        }

        /// Sends a command without waiting for its answer, for one that may end the connection.
        func post(_ method: String) {
            let message: [String: Any] = ["id": nextId(), "method": method, "params": [:] as [String: Any]]
            if let data = try? JSONSerialization.data(withJSONObject: message) {
                task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
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
                    closedError = E2EError("\(name): connection lost: \(error)")
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
                            finish(id, .failure(ProtocolError(description: "\(name): \(error["message"] as? String ?? "\(error)")")))
                        }
                        else if let error = body["error"] as? String {
                            finish(id, .failure(ProtocolError(description: "\(name): \(error): \(body["message"] as? String ?? "")")))
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

    /// Serves the run's pages over HTTP on 127.0.0.1, for the browsers: some of what a page does
    /// (`history.pushState`) isn't allowed on `file://` pages in Chrome.
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

        /// Fails if the listener isn't ready within 5 s, or stops or waits (for a network that
        /// isn't there) before.
        func start() async throws {
            listener.newConnectionHandler = { [self] connection in
                serve(connection)
            }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, port != 0 {
                        finishStart(.success(port))
                    }
                    else {
                        finishStart(.failure(E2EError("page server: ready without a port")))
                    }
                case .failed(let error):
                    finishStart(.failure(E2EError("page server: \(error)")))
                case .waiting(let error):
                    finishStart(.failure(E2EError("page server: waiting: \(error)")))
                case .cancelled:
                    finishStart(.failure(E2EError("page server: cancelled before it was ready")))
                default:
                    break
                }
            }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    whenReady = continuation
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 5) { [self] in
                        finishStart(.failure(E2EError("page server: not ready in 5 s")))
                    }
                }
            }
            base = "http://127.0.0.1:\(port)"
        }

        /// On `queue`. Only the first call counts; a failure also stops the listener.
        private func finishStart(_ result: Result<UInt16, Error>) {
            guard let whenReady else {
                return
            }
            self.whenReady = nil
            if case .failure = result {
                listener.cancel()
            }
            whenReady.resume(with: result)
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

extension E2E.Browser {
    /// Waits up to 5 s for `js` to be true in the tab. A script that throws, or that the browser
    /// refuses to run (the page is between documents), counts as false. Anything else, such as a
    /// lost connection, fails at once.
    func waitUntil(_ tab: Tab, _ js: String, _ failure: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let isTrue: Bool
            do {
                isTrue = try await eval(tab, js) as? Bool == true
            }
            catch is E2E.ScriptError {
                isTrue = false
            }
            catch is E2E.BrowserSocket.ProtocolError {
                isTrue = false
            }
            if isTrue {
                return
            }
            guard Date() < deadline else {
                throw E2EError("\(Self.name): \(failure)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Checks the step's premise: this tab is the one shown, in the window that has keyboard
    /// focus, with the browser in front.
    func expectFocus(_ tab: Tab) async throws {
        guard try E2E.frontmostPid() == pid else {
            throw E2EError("\(Self.name) isn't in front")
        }
        try await waitUntil(tab, "document.visibilityState === 'visible' && document.hasFocus()", "the tab isn't the one shown with focus")
    }

    /// Waits until the tab has loaded `url`.
    func waitUntilLoaded(_ tab: Tab, _ url: String) async throws {
        try await waitUntil(tab, "document.readyState === 'complete' && location.href === \(E2E.jsString(url))", "\(url) didn't load")
    }
}

extension E2E.App {
    /// The app at `url`, from its Info.plist.
    init(bundleAt url: URL) throws {
        guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else {
            throw E2EError("\(url.path) isn't an app")
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? bundle.object(forInfoDictionaryKey: "CFBundleName")
        self.init(bundleId: bundleId, path: url.path, name: name as? String ?? "")
    }
}
