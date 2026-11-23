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
    /// URL and title of the page in the focused window's web content (apps whose pages are read,
    /// see `PageReadingPolicy`).
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
    /// Whether the frontmost app's pages are read (page reading is on), so its pages need watching.
    let isReadingPages: Bool
    /// The page element `snapshot.url` was read from, to watch for changes.
    let pageElement: AXUIElement?
}

final class Sampler {
    /// No input for this long counts as idle. The away rule (N minutes, with exceptions) belongs to the server.
    static let idleThresholdSeconds: Double = 60

    // `kCGAnyInputEventType` (~0) is not imported into Swift.
    private static let anyInputEventType = CGEventType(rawValue: ~0)!

    private let webAreas = WebAreaReader()
    private let pageReading: PageReadingPolicy

    init(pageReading: PageReadingPolicy) {
        self.pageReading = pageReading
    }

    func sample(nowMs: Int64, isScreenLocked: Bool, isAxTrusted: Bool) -> Sample {
        if isScreenLocked {
            pageReading.noteSample(app: nil, mode: .off, isActive: false, atMs: nowMs)
            return Sample(
                snapshot: Snapshot(isScreenLocked: true),
                idleSinceMs: nil,
                frontmostPID: nil,
                isReadingPages: false,
                pageElement: nil
            )
        }
        pageReading.refresh()
        var snapshot = Snapshot()
        var page: WebPage?
        let frontmost = NSWorkspace.shared.frontmostApplication
        let identity = AppIdentity(bundleID: frontmost?.bundleIdentifier, executablePath: frontmost?.executableURL?.path)
        let mode = identity.map(pageReading.mode(for:)) ?? .off
        if let app = frontmost {
            snapshot.bundleID = app.bundleIdentifier
            snapshot.appName = app.localizedName
            snapshot.bundlePath = app.bundleURL?.path
            snapshot.executablePath = app.executableURL?.path
            if isAxTrusted {
                let pid = app.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                if let window = readFocusedWindow(of: appElement, into: &snapshot), let identity {
                    page = readPage(mode: mode, app: identity, appElement: appElement, pid: pid, window: window, bundlePath: snapshot.bundlePath, atMs: nowMs)
                    snapshot.url = page?.url
                    snapshot.pageTitle = page?.title
                }
            }
        }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEventType)
        var idleSinceMs: Int64? = nil
        // isFinite: Int64(Double) traps on infinity or NaN.
        if idleSeconds.isFinite && idleSeconds >= Self.idleThresholdSeconds {
            snapshot.isIdle = true
            idleSinceMs = nowMs - Int64(min(idleSeconds, 365 * 24 * 3600) * 1000)
        }
        pageReading.noteSample(app: identity, mode: mode, isActive: !snapshot.isIdle, atMs: nowMs)
        return Sample(
            snapshot: snapshot,
            idleSinceMs: idleSinceMs,
            frontmostPID: frontmost?.processIdentifier,
            // A probe that found a page has just switched page reading on.
            isReadingPages: mode == .on || page != nil,
            pageElement: page?.element
        )
    }

    /// The page to record, per the app's page reading mode. While probing, only a probe that
    /// finds a page returns it: the app is on from then on, so this sample can use it already.
    private func readPage(
        mode: PageReadingMode,
        app: AppIdentity,
        appElement: AXUIElement,
        pid: pid_t,
        window: AXUIElement,
        bundlePath: String?,
        atMs nowMs: Int64
    ) -> WebPage? {
        switch mode {
        case .off:
            return nil
        case .on:
            let pages = webAreas.pages(app: appElement, pid: pid, bundlePath: bundlePath, window: window)
            return webAreas.choose(from: pages, app: appElement, bundlePath: bundlePath)
        case .probing:
            guard pageReading.isProbeDue(pid: pid, window: window, atMs: nowMs) else {
                return nil
            }
            let pages = webAreas.pages(app: appElement, pid: pid, bundlePath: bundlePath, window: window)
            pageReading.noteProbe(app: app, pid: pid, window: window, hasContentPages: !pages.isEmpty, atMs: nowMs)
            return webAreas.choose(from: pages, app: appElement, bundlePath: bundlePath)
        }
    }

    /// Fills in the focused window's attributes. Returns the window, nil if there is none.
    private func readFocusedWindow(of app: AXUIElement, into snapshot: inout Snapshot) -> AXUIElement? {
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
        return window
    }
}
