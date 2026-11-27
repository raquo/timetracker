import AppKit
import ApplicationServices

/// The end-to-end tests' helper (docs/end-to-end-tests.md, "The helper"): holds the Accessibility
/// permission and does only what needs it. Windowless (`LSUIElement`). Never sends input.
///
/// `E2EHelper --check-access <file>`: writes `trusted` or `untrusted` to `<file>` and exits.
/// Run through `open`, so the answer is this app's permission, not the terminal's.
///
/// `E2EHelper --control <dir>`: runs the commands the test writes to `<dir>/cmd-<n>.json`
/// (n = 1, 2, …, in order, one at a time) and answers each in `<dir>/ack-<n>.json` once done:
/// `{"result": …}` or `{"error": "…"}`. The same loop as `E2ETarget`'s, minus its async commands.
/// Exits once `<dir>` is gone, so a run that died without cleaning up doesn't leave it running.
/// Commands (`op`, plus its fields):
/// - `checkAccess`: answers `{"isTrusted": …}` (`AXIsProcessTrusted`, never prompts).
/// - `focusAddressBar`: `pid` of a Chrome; moves keyboard focus to the address bar of its
///   focused window, and answers once Chrome reports it there (`AXFocusedUIElement`).
/// - `focusPage`: `pid`, `url`; moves keyboard focus to the page (`AXWebArea`) with that URL in
///   the app's focused window, and answers once the app reports focus in it.
/// Both set `AXFocused` on that one element and wait up to 2 s (`AX.timeoutSeconds`).
final class Controller: NSObject, NSApplicationDelegate {
    private let controlDir: URL
    private var next = 1

    init(controlDir: URL) {
        self.controlDir = controlDir
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: controlDir.path) else {
            exit(0)
        }
        let file = controlDir.appendingPathComponent("cmd-\(next).json")
        guard let data = try? Data(contentsOf: file) else {
            return
        }
        let n = next
        next += 1
        guard let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ack(n, ["error": "unreadable command"])
            return
        }
        do {
            ack(n, ["result": try run(command) ?? NSNull()])
        }
        catch {
            ack(n, ["error": "\(error)"])
        }
    }

    /// Runs the command to the end; returns its result.
    private func run(_ c: [String: Any]) throws -> Any? {
        let op = c["op"] as? String ?? ""
        switch op {
        case "checkAccess":
            return ["isTrusted": AXIsProcessTrusted()]
        case "focusAddressBar":
            guard let pid = c["pid"] as? Int else {
                throw CommandError("missing pid")
            }
            try Chrome.focusAddressBar(pid_t(pid))
            return nil
        case "focusPage":
            guard let pid = c["pid"] as? Int, let url = c["url"] as? String else {
                throw CommandError("missing pid or url")
            }
            try AX.focusPage(pid_t(pid), url: url)
            return nil
        default:
            throw CommandError("unknown op \(op)")
        }
    }

    private func ack(_ n: Int, _ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed)) ?? Data("{\"error\": \"unencodable answer\"}".utf8)
        try? data.write(to: controlDir.appendingPathComponent("ack-\(n).json"), options: .atomic)
    }
}

/// Chrome's own UI.
enum Chrome {
    /// The address bar's `AXDescription` (English UI), a text field in the window's toolbar.
    static let addressBarDescription = "Address and search bar"

    /// Sets `AXFocused` on the address bar of the app's focused window, then waits for the app's
    /// `AXFocusedUIElement` to be it.
    static func focusAddressBar(_ pid: pid_t) throws {
        let (app, window) = try AX.focusedWindow(pid)
        let toolbars = AX.descendants(of: window, maxDepth: 8) { AX.role($0) == kAXToolbarRole }
        guard !toolbars.isEmpty else {
            throw CommandError("no AXToolbar in the focused window of pid \(pid)")
        }
        let fields = toolbars.flatMap { AX.descendants(of: $0, maxDepth: 4) { AX.role($0) == kAXTextFieldRole } }
        guard let field = fields.first(where: { AX.description($0) == addressBarDescription }) else {
            let found = fields.map { "\"\(AX.description($0) ?? "")\"" }.joined(separator: ", ")
            throw CommandError("no text field described \"\(addressBarDescription)\" in the toolbar of pid \(pid); text fields there: \(found.isEmpty ? "none" : found)")
        }
        try AX.setFocus(field, "the address bar", in: app) { CFEqual($0, field) }
    }
}

/// Accessibility reads and focus changes, for any app.
enum AX {
    /// How long to wait for focus to arrive, and for the app to answer each call.
    static let timeoutSeconds: Float = 2

    /// Sets `AXFocused` on the web area showing `url` in the app's focused window, then waits for
    /// the app's `AXFocusedUIElement` to be it or inside it.
    static func focusPage(_ pid: pid_t, url: String) throws {
        let (app, window) = try focusedWindow(pid)
        let pages = descendants(of: window, maxDepth: 30) { role($0) == "AXWebArea" }
        guard let page = pages.first(where: { pageUrl($0) == url }) else {
            let found = pages.map { pageUrl($0) ?? "no URL" }.joined(separator: ", ")
            throw CommandError("no page \(url) in the focused window of pid \(pid); pages there: \(found.isEmpty ? "none" : found)")
        }
        try setFocus(page, "the page", in: app) { focused in
            var element: AXUIElement? = focused
            while let e = element {
                if CFEqual(e, page) {
                    return true
                }
                element = attribute(e, kAXParentAttribute)
            }
            return false
        }
    }

    static func focusedWindow(_ pid: pid_t) throws -> (app: AXUIElement, window: AXUIElement) {
        guard AXIsProcessTrusted() else {
            throw CommandError("no Accessibility permission")
        }
        // On the system-wide element, so it applies to every element, not just this one.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeoutSeconds)
        let app = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else {
            throw CommandError("pid \(pid) has no focused window")
        }
        return (app, window)
    }

    /// Sets `AXFocused` on `element`, then waits up to `timeoutSeconds` for the app's
    /// `AXFocusedUIElement` to pass `isThere`. `name` names the element in errors.
    static func setFocus(_ element: AXUIElement, _ name: String, in app: AXUIElement, isThere: (AXUIElement) -> Bool) throws {
        let error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard error == .success else {
            throw CommandError("setting AXFocused on \(name) failed: \(error.rawValue)")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            let focused: AXUIElement? = attribute(app, kAXFocusedUIElementAttribute)
            if let focused, isThere(focused) {
                return
            }
            guard Date() < deadline else {
                let what = focused.map { "\(role($0) ?? "?") \"\(description($0) ?? "")\"" } ?? "nothing"
                throw CommandError("\(name) didn't take focus; focused: \(what)")
            }
            usleep(50_000)
        }
    }

    static func pageUrl(_ element: AXUIElement) -> String? {
        (attribute(element, "AXURL") as URL?)?.absoluteString
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return nil
        }
        // AXUIElement can't be cast with `as?`: compare type IDs.
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    static func description(_ element: AXUIElement) -> String? {
        attribute(element, kAXDescriptionAttribute)
    }

    /// Breadth first, not counting `root`; doesn't look inside matches.
    static func descendants(of root: AXUIElement, maxDepth: Int, _ matches: (AXUIElement) -> Bool) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var level = [root]
        for _ in 0..<maxDepth {
            var nextLevel: [AXUIElement] = []
            for element in level {
                for child in attribute(element, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
                    if matches(child) {
                        found.append(child)
                    }
                    else {
                        nextLevel.append(child)
                    }
                }
            }
            level = nextLevel
        }
        return found
    }
}

struct CommandError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--check-access"), i + 1 < arguments.count {
    let answer = AXIsProcessTrusted() ? "trusted" : "untrusted"
    do {
        try answer.write(toFile: arguments[i + 1], atomically: true, encoding: .utf8)
        exit(0)
    }
    catch {
        FileHandle.standardError.write(Data("E2EHelper: \(error)\n".utf8))
        exit(1)
    }
}
guard let i = arguments.firstIndex(of: "--control"), i + 1 < arguments.count else {
    FileHandle.standardError.write(Data("usage: E2EHelper --control <dir> | --check-access <file>\n".utf8))
    exit(2)
}
let app = NSApplication.shared
let controller = Controller(controlDir: URL(fileURLWithPath: arguments[i + 1]))
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
