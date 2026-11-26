import AppKit
import ApplicationServices

/// Diagnostic: `TimeTracker --dump-ax <bundle-id> <output-file> [--json]` writes to a file what
/// a running app exposes:
/// - text: the tracker's web area search on each of its windows (elements visited, time, web
///   areas found), then the focused window's attributes and Accessibility tree;
/// - `--json`: the focused window as an `AxFixture`, for tests. Errors are written as text.
///
/// Must run as the installed app (e.g. via `open -n -W TimeTracker.app --args --dump-ax ...`)
/// so that it has the tracker's Accessibility permission. Doesn't touch the database.
///
/// Switches on the app's web tree (`AXManualAccessibility`) and leaves it on, like the tracker:
/// Electron apps report the flag as false even while it's on, so we can't tell whether to restore it.
enum AxDump {
    static let maxDepth = 60
    static let maxNodes = 8000
    static let maxValueLength = 80

    enum Format: Equatable {
        case text
        case json
    }

    static func run(bundleId: String, outputPath: String, format: Format) -> Int32 {
        var out = ""
        func line(_ s: String) {
            out += s + "\n"
        }
        defer {
            try? out.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        Accessibility.setGlobalTimeout()
        line("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            line("no running app with bundle ID \(bundleId)")
            return 1
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let setResult = appElement.set(AxName.manualAccessibility, true)
        line("set \(AxName.manualAccessibility) true: \(setResult.rawValue)")
        // Electron builds the web tree lazily after the flag is set.
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        guard let window = appElement.focusedWindow else {
            line("no focused window")
            return 1
        }
        if format == .json {
            let fixture = AxFixture.capture(app: appElement, window: window, bundleId: bundleId, bundlePath: app.bundleURL?.path)
            do {
                out = String(decoding: try fixture.encoded(), as: UTF8.self) + "\n"
                return 0
            }
            catch {
                line("encoding failed: \(error)")
                return 1
            }
        }
        let windows = [window] + appElement.elements(kAXWindowsAttribute).filter { $0 != window }
        for (i, w) in windows.enumerated() {
            let started = Date()
            let result = PageSearch.webAreas(in: w)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            let title = w.string(kAXTitleAttribute) ?? "untitled"
            line("search window \(i) (\(title)): visited \(result.visited) elements, \(elapsedMs) ms, \(result.webAreas.count) web areas")
            for area in result.webAreas {
                let url = area.url(AxName.url)?.absoluteString ?? "nil"
                line("  web area: url=\(url) | title=\(area.string(kAXTitleAttribute).map(truncate) ?? "nil")")
            }
        }

        var names: CFArray?
        if AXUIElementCopyAttributeNames(window, &names) == .success, let names = names as? [String] {
            line("window attributes: \(names.joined(separator: ", "))")
        }
        line("window AXDocument: \(window.string(kAXDocumentAttribute) ?? "nil")")
        var count = 0
        walk(window, depth: 0, count: &count, line: line)
        line("nodes: \(count)")
        return 0
    }

    private static func walk(_ element: AXUIElement, depth: Int, count: inout Int, line: (String) -> Void) {
        guard depth <= maxDepth, count < maxNodes else {
            return
        }
        count += 1
        var parts: [String] = [String(repeating: "  ", count: depth) + (element.role ?? "?")]
        if let subrole = element.string(kAXSubroleAttribute) {
            parts.append("sub=\(subrole)")
        }
        for (label, attribute) in [
            ("title", kAXTitleAttribute),
            ("desc", kAXDescriptionAttribute),
            ("value", kAXValueAttribute),
            ("domId", AxName.domIdentifier),
        ] {
            if let s = element.string(attribute) {
                parts.append("\(label)=\(truncate(s))")
            }
        }
        if let url = element.url(AxName.url) {
            parts.append("url=\(url.absoluteString)")
        }
        line(parts.joined(separator: " | "))
        if element.role == AxName.webAreaRole {
            // Every attribute, in case one holds what the URL doesn't (Claude's ⌘-click windows report about:blank).
            let indent = String(repeating: "  ", count: depth + 1)
            var names: CFArray?
            if AXUIElementCopyAttributeNames(element, &names) == .success, let names = names as? [String] {
                for name in names.sorted() where name != kAXChildrenAttribute && name != kAXParentAttribute {
                    let value = element.value(name).map { String(describing: $0) } ?? "nil"
                    line("\(indent)· \(name) = \(truncate(value))")
                }
            }
        }
        for child in element.children {
            walk(child, depth: depth + 1, count: &count, line: line)
        }
    }

    private static func truncate(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: "⏎")
        return oneLine.count > maxValueLength ? String(oneLine.prefix(maxValueLength)) + "…" : oneLine
    }
}
