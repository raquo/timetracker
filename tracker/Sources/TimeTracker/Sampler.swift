import AppKit
import ApplicationServices

/// The raw attributes of one moment. Consecutive equal snapshots merge into one interval.
struct Snapshot: Equatable {
    var bundleID: String? = nil
    var appName: String? = nil
    /// The .app bundle's path, or nil for a process without one.
    var bundlePath: String? = nil
    var executablePath: String? = nil
    var windowTitle: String? = nil
    /// AXRole / AXSubrole of the focused window. Tells panels and popups apart from normal windows.
    var windowRole: String? = nil
    var windowSubrole: String? = nil
    /// nil: not reported (no focused window, or no Accessibility permission).
    var isMainWindow: Bool? = nil
    var isFullScreen: Bool? = nil
    var documentPath: String? = nil
    /// URL and title of the page in the focused window's web content (allowlisted apps only).
    var url: String? = nil
    var pageTitle: String? = nil
    var isIdle = false
    var isScreenLocked = false
}

/// A snapshot, plus what the tracker needs to know about where it came from.
struct Sample {
    let snapshot: Snapshot
    /// When `snapshot.isIdle`: the time of the last user input.
    let idleSinceMs: Int64?
    let frontmostPID: pid_t?
    /// Whether the frontmost app is on the web content allowlist.
    let isWebContentApp: Bool
    /// The page element `snapshot.url` was read from, to watch for changes.
    let pageElement: AXUIElement?
}

final class Sampler {
    /// No input for this long counts as idle. The away rule (N minutes, with exceptions) belongs to the server.
    static let idleThresholdSeconds: Double = 60

    // `kCGAnyInputEventType` (~0) is not imported into Swift.
    private static let anyInputEventType = CGEventType(rawValue: ~0)!

    private let webAreas = WebAreaReader()

    func sample(nowMs: Int64, isScreenLocked: Bool, isAxTrusted: Bool) -> Sample {
        if isScreenLocked {
            return Sample(
                snapshot: Snapshot(isScreenLocked: true),
                idleSinceMs: nil,
                frontmostPID: nil,
                isWebContentApp: false,
                pageElement: nil
            )
        }
        var snapshot = Snapshot()
        var page: WebPage?
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isWebContentApp = webAreas.isEnabled(for: frontmost?.bundleIdentifier)
        if let app = frontmost {
            snapshot.bundleID = app.bundleIdentifier
            snapshot.appName = app.localizedName
            snapshot.bundlePath = app.bundleURL?.path
            snapshot.executablePath = app.executableURL?.path
            if isAxTrusted {
                page = readFocusedWindow(of: app, readPage: isWebContentApp, into: &snapshot)
            }
        }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEventType)
        var idleSinceMs: Int64? = nil
        // isFinite: Int64(Double) traps on infinity or NaN.
        if idleSeconds.isFinite && idleSeconds >= Self.idleThresholdSeconds {
            snapshot.isIdle = true
            idleSinceMs = nowMs - Int64(min(idleSeconds, 365 * 24 * 3600) * 1000)
        }
        return Sample(
            snapshot: snapshot,
            idleSinceMs: idleSinceMs,
            frontmostPID: frontmost?.processIdentifier,
            isWebContentApp: isWebContentApp,
            pageElement: page?.element
        )
    }

    /// Fills in the focused window's attributes. Returns the web page read, if any.
    private func readFocusedWindow(
        of runningApp: NSRunningApplication,
        readPage: Bool,
        into snapshot: inout Snapshot
    ) -> WebPage? {
        let pid = runningApp.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        guard let window = app.focusedWindow else {
            return nil
        }
        snapshot.windowTitle = window.string(kAXTitleAttribute)
        snapshot.windowRole = window.role
        snapshot.windowSubrole = window.string(kAXSubroleAttribute)
        snapshot.isMainWindow = window.bool(kAXMainAttribute)
        snapshot.isFullScreen = window.bool(AXName.fullScreen)
        // AXDocument is a URL string, usually file://. Store file URLs as plain paths.
        snapshot.documentPath = window.string(kAXDocumentAttribute).map { doc in
            if let url = URL(string: doc), url.isFileURL {
                return url.path
            }
            else {
                return doc
            }
        }
        guard readPage, let bundleID = runningApp.bundleIdentifier else {
            return nil
        }
        let page = webAreas.page(app: app, pid: pid, bundleID: bundleID, bundlePath: snapshot.bundlePath, window: window)
        snapshot.url = page?.url
        snapshot.pageTitle = page?.title
        return page
    }
}
