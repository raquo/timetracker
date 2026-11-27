import AppKit
import ApplicationServices

/// Diagnostic: `TimeTracker --watch-ax <bundle-id or pid> <output-file> <seconds>` logs, for that long,
/// which Accessibility notifications a running app sends and for which elements, to find out
/// what the tracker could listen for. Registers each notification three times: on the app, on
/// the focused window, and on the focused window's web area (re-registered when that changes);
/// each line says which one it came through, since apps don't deliver every notification to an
/// app-wide registration. Also logs whenever the web area changes: a new element, URL or title
/// (polled every 100 ms), since a new element means notifications registered on the old one stop.
///
/// Like `--dump-ax`, must run as the installed app (or the build copy) for the tracker's
/// Accessibility permission. Lines are written as they come, in ms since the start (the first
/// line gives the start in Unix ms, to line up with other logs). A pid picks one copy of an app
/// that runs more than once (a second Chrome with its own profile has the same bundle ID).
enum AxWatch {
    /// Notifications an element doesn't support are refused at registration; those are logged
    /// for the app element only, since many elements refuse many of them.
    static let notifications = [
        kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXMainWindowChangedNotification, kAXWindowCreatedNotification, kAXTitleChangedNotification,
        kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXCreatedNotification,
        kAXLayoutChangedNotification, kAXSelectedTextChangedNotification,
        kAXSelectedChildrenChangedNotification, kAXRowCountChangedNotification,
        kAXElementBusyChangedNotification, kAXAnnouncementRequestedNotification,
        AxName.loadCompleteNotification, "AXLayoutComplete", "AXLiveRegionChanged",
        "AXExpandedChanged", "AXInvalidStatusChanged", "AXCurrentStateChanged",
        "AXActiveElementChanged", "AXURLChanged",
    ]

    static func run(app target: String, outputPath: String, seconds: Double) -> Int32 {
        guard FileManager.default.createFile(atPath: outputPath, contents: nil), let out = FileHandle(forWritingAtPath: outputPath) else {
            FileHandle.standardError.write(Data("can't write \(outputPath)\n".utf8))
            return 1
        }
        let startedAt = Date()
        func line(_ s: String) {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            out.write(Data("\(String(format: "%6d", ms)) \(s)\n".utf8))
        }
        Accessibility.setGlobalTimeout()
        line("started at \(Int64(startedAt.timeIntervalSince1970 * 1000)) Unix ms")
        line("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        let found: NSRunningApplication?
        if let pid = pid_t(target) {
            found = NSRunningApplication(processIdentifier: pid)
        }
        else {
            found = NSRunningApplication.runningApplications(withBundleIdentifier: target).first
        }
        guard let app = found else {
            line("no running app \(target)")
            return 1
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, axWatchCallback, &created) == .success, let observer = created else {
            line("AXObserverCreate failed")
            return 1
        }
        let sinks = ["app", "window", "page"].map { via in Sink { line("[\(via)] \($0)") } }
        func register(_ element: AXUIElement, _ sink: Sink, isLogged: Bool) {
            for name in notifications {
                let result = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(sink).toOpaque())
                if isLogged, result != .success {
                    line("register \(name): error \(result.rawValue)")
                }
            }
        }
        func unregister(_ element: AXUIElement) {
            for name in notifications {
                AXObserverRemoveNotification(observer, element, name as CFString)
            }
        }
        register(appElement, sinks[0], isLogged: true)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        var lastWindow: AXUIElement?
        var lastPage: AXUIElement?
        var lastPageText = ""
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            let window = appElement.focusedWindow
            if window != lastWindow {
                if let lastWindow {
                    unregister(lastWindow)
                }
                if let window {
                    register(window, sinks[1], isLogged: false)
                }
                line("window: \(window.map(describe) ?? "none")")
                lastWindow = window
            }
            let page = window.flatMap { firstWebArea(under: $0, depth: 0) }
            let text = page.map(describe) ?? "none"
            let isNewElement: Bool
            if let page, let old = lastPage {
                isNewElement = page != old
            }
            else {
                isNewElement = (page == nil) != (lastPage == nil)
            }
            if isNewElement || text != lastPageText {
                line("page\(isNewElement ? " (new element)" : ""): \(text)")
            }
            if isNewElement {
                if let lastPage {
                    unregister(lastPage)
                }
                if let page {
                    register(page, sinks[2], isLogged: false)
                }
            }
            lastPage = page
            lastPageText = text
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        withExtendedLifetime(sinks) {}
        line("done")
        return 0
    }

    fileprivate final class Sink {
        let line: (String) -> Void
        init(_ line: @escaping (String) -> Void) {
            self.line = line
        }
    }

    fileprivate static func describe(_ element: AXUIElement) -> String {
        var parts = [element.role ?? "no role"]
        if let title = element.string(kAXTitleAttribute) {
            parts.append("title \"\(title)\"")
        }
        if let description = element.string(kAXDescriptionAttribute) {
            parts.append("description \"\(description)\"")
        }
        if let url = element.url(AxName.url) {
            parts.append("url \(url.absoluteString)")
        }
        parts.append("#\(String(CFHash(element), radix: 16))")
        return parts.joined(separator: " ")
    }

    private static func firstWebArea(under element: AXUIElement, depth: Int) -> AXUIElement? {
        if element.role == AxName.webAreaRole {
            return element
        }
        guard depth < 20 else {
            return nil
        }
        for child in element.children {
            if let found = firstWebArea(under: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}

private func axWatchCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else {
        return
    }
    let sink = Unmanaged<AxWatch.Sink>.fromOpaque(refcon).takeUnretainedValue()
    sink.line("\(notification as String): \(AxWatch.describe(element))")
}
