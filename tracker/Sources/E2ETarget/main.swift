import AppKit
import WebKit

/// The app the end-to-end tests drive (see Tests/TrackerE2ETests): windows with known titles,
/// plain or holding web views, so the real tracker can be checked against what's on screen.
///
/// `E2ETarget --control <dir>`: runs the commands the test writes to `<dir>/cmd-<n>.json`
/// (n = 1, 2, …, in order, one at a time) and answers each in `<dir>/ack-<n>.json` once done:
/// `{"result": …}` (the script's result for `eval`, else null) or `{"error": "…"}`.
/// Exits once `<dir>` is gone, so a run that died without cleaning up doesn't leave it running.
/// Commands (`op`, plus its fields):
/// - `openWindow`: `id` (new), `title`, `pages` (URLs; none: a plain window, 2+: side by side),
///   `isFocusCleared` (no keyboard focus in it, else AppKit focuses the first web view),
///   `isPanel` (a utility panel instead of a standard window); brings it to the front and waits
///   for the pages to load.
/// - `focusWindow`: `id`.
/// - `closeWindow`: `id`.
/// - `setTitle`: `id`, `title`.
/// - `navigate`: `id`, `index`, `url`; waits for the load.
/// - `focusPage`: `id`, `index`: keyboard focus to that web view.
/// - `eval`: `id`, `index`, `js`; answers with the script's result (null if it has none).
final class Target: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private struct Window {
        let window: NSWindow
        let webViews: [WKWebView]
    }

    private let controlDir: URL
    private var next = 1
    private var windows: [String: Window] = [:]
    /// Web views still loading, and the command waiting for them.
    private var loading: Set<ObjectIdentifier> = []
    private var whenLoaded: ((String?) -> Void)?
    private var isBusy = false

    init(controlDir: URL) {
        self.controlDir = controlDir
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: controlDir.path) else {
            exit(0)
        }
        guard !isBusy else {
            return
        }
        let file = controlDir.appendingPathComponent("cmd-\(next).json")
        guard let data = try? Data(contentsOf: file) else {
            return
        }
        let n = next
        next += 1
        isBusy = true
        guard let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ack(n, ["error": "unreadable command"])
            return
        }
        do {
            try run(command) { [weak self] result, error in
                if let error {
                    self?.ack(n, ["error": error])
                }
                else {
                    self?.ack(n, ["result": result ?? NSNull()])
                }
            }
        }
        catch {
            ack(n, ["error": "\(error)"])
        }
    }

    /// Calls `done` once the command has taken effect: at once, or after loads or a script.
    private func run(_ c: [String: Any], done: @escaping (_ result: Any?, _ error: String?) -> Void) throws {
        let op = c["op"] as? String ?? ""
        switch op {
        case "openWindow":
            let id = try field(c, "id", String.self)
            guard windows[id] == nil else {
                throw TargetError("window \(id) is already open")
            }
            let pages = try (c["pages"] as? [String] ?? []).map(url)
            let frame = NSRect(x: 200 + windows.count * 40, y: 200, width: 900, height: 600)
            let window: NSWindow
            if c["isPanel"] as? Bool == true {
                window = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            }
            else {
                window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            }
            window.isReleasedWhenClosed = false
            window.title = try field(c, "title", String.self)
            var webViews: [WKWebView] = []
            for _ in pages {
                let webView = WKWebView(frame: .zero)
                webView.navigationDelegate = self
                webViews.append(webView)
            }
            if webViews.isEmpty {
                window.contentView = NSView()
            }
            else {
                let stack = NSStackView(views: webViews)
                stack.orientation = .horizontal
                stack.distribution = .fillEqually
                window.contentView = stack
            }
            windows[id] = Window(window: window, webViews: webViews)
            window.makeKeyAndOrderFront(nil)
            if c["isFocusCleared"] as? Bool == true {
                // Else AppKit gives keyboard focus to the first web view.
                window.makeFirstResponder(nil)
            }
            for (webView, page) in zip(webViews, pages) {
                load(webView, page)
            }
            afterLoads { done(nil, $0) }
        case "focusWindow":
            try window(c).window.makeKeyAndOrderFront(nil)
            done(nil, nil)
        case "closeWindow":
            let id = try field(c, "id", String.self)
            try window(c).window.close()
            windows[id] = nil
            done(nil, nil)
        case "setTitle":
            try window(c).window.title = try field(c, "title", String.self)
            done(nil, nil)
        case "navigate":
            load(try webView(c), try url(try field(c, "url", String.self)))
            afterLoads { done(nil, $0) }
        case "focusPage":
            let w = try window(c)
            guard w.window.makeFirstResponder(try webView(c)) else {
                throw TargetError("the web view didn't take focus")
            }
            done(nil, nil)
        case "eval":
            try webView(c).evaluateJavaScript(try field(c, "js", String.self)) { result, error in
                // A script without a result (e.g. `postMessage(…)`) reports an unsupported type.
                if let error = error as? WKError, error.code != .javaScriptResultTypeIsUnsupported {
                    done(nil, "\(error)")
                }
                else {
                    done(result, nil)
                }
            }
        default:
            throw TargetError("unknown op \(op)")
        }
    }

    private func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw TargetError("bad URL \(string)")
        }
        return url
    }

    private func load(_ webView: WKWebView, _ url: URL) {
        loading.insert(ObjectIdentifier(webView))
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Calls `done` once nothing is loading: with nil, or with the error of a load that failed.
    private func afterLoads(_ done: @escaping (String?) -> Void) {
        whenLoaded = done
        finishIfLoaded(error: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading.remove(ObjectIdentifier(webView))
        finishIfLoaded(error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading.remove(ObjectIdentifier(webView))
        finishIfLoaded(error: "load failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading.remove(ObjectIdentifier(webView))
        finishIfLoaded(error: "load failed: \(error)")
    }

    /// A failed load answers at once; the other loads still finish, unwaited.
    private func finishIfLoaded(error: String?) {
        guard let done = whenLoaded, loading.isEmpty || error != nil else {
            return
        }
        whenLoaded = nil
        done(error)
    }

    private func ack(_ n: Int, _ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed)) ?? Data("{\"error\": \"unencodable answer\"}".utf8)
        try? data.write(to: controlDir.appendingPathComponent("ack-\(n).json"), options: .atomic)
        isBusy = false
    }

    private func window(_ c: [String: Any]) throws -> Window {
        let id = try field(c, "id", String.self)
        guard let w = windows[id] else {
            throw TargetError("no window \(id)")
        }
        return w
    }

    private func webView(_ c: [String: Any]) throws -> WKWebView {
        let w = try window(c)
        let index = c["index"] as? Int ?? 0
        guard w.webViews.indices.contains(index) else {
            throw TargetError("no web view \(index) in window")
        }
        return w.webViews[index]
    }

    private func field<T>(_ c: [String: Any], _ name: String, _ type: T.Type) throws -> T {
        guard let value = c[name] as? T else {
            throw TargetError("missing \(name)")
        }
        return value
    }
}

struct TargetError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

let arguments = CommandLine.arguments
guard let i = arguments.firstIndex(of: "--control"), i + 1 < arguments.count else {
    FileHandle.standardError.write(Data("usage: E2ETarget --control <dir>\n".utf8))
    exit(2)
}
let app = NSApplication.shared
let target = Target(controlDir: URL(fileURLWithPath: arguments[i + 1]))
app.delegate = target
app.setActivationPolicy(.regular)
app.run()
