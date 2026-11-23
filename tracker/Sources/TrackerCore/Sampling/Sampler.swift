import AppKit
import ApplicationServices

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

/// Reads what's on screen right now from macOS: the frontmost app, its focused window and page
/// (per `PageReadingPolicy`), and idle time.
///
/// Confined to the tracker's queue.
final class Sampler {
    /// No input for this long counts as idle. The away rule (N minutes, with exceptions) belongs to the server.
    static let idleThresholdSeconds: Double = 60

    // `kCGAnyInputEventType` (~0) is not imported into Swift.
    private static let anyInputEventType = CGEventType(rawValue: ~0)!

    private let electronTree = ElectronTreeSwitch()
    private let pageReading: PageReadingPolicy

    init(pageReading: PageReadingPolicy) {
        self.pageReading = pageReading
    }

    func sample(nowMs: Int64, isScreenLocked: Bool, isAxTrusted: Bool) -> Sample {
        if isScreenLocked {
            pageReading.noteSample(app: nil, mode: .off, isActive: false, hasProbeableWindow: false, atMs: nowMs)
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
        var page: WebPage<AXUIElement>?
        var hasProbeableWindow = false
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let app = frontmost {
            snapshot.bundleID = app.bundleIdentifier
            snapshot.appName = app.localizedName
            snapshot.bundlePath = app.bundleURL?.path
            snapshot.executablePath = app.executableURL?.path
        }
        let identity = snapshot.app
        let mode = identity.map(pageReading.mode(for:)) ?? .off
        if let frontmost, isAxTrusted {
            let pid = frontmost.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            if let window = readFocusedWindow(of: appElement, into: &snapshot), let identity {
                hasProbeableWindow = true
                page = readPage(mode: mode, app: identity, appElement: appElement, pid: pid, window: window, bundlePath: snapshot.bundlePath, atMs: nowMs)
                snapshot.url = page?.url
                snapshot.pageTitle = page?.title
            }
        }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEventType)
        var idleSinceMs: Int64? = nil
        // isFinite: Int64(Double) traps on infinity or NaN.
        if idleSeconds.isFinite && idleSeconds >= Self.idleThresholdSeconds {
            snapshot.isIdle = true
            idleSinceMs = nowMs - Int64(min(idleSeconds, 365 * 24 * 3600) * 1000)
        }
        pageReading.noteSample(app: identity, mode: mode, isActive: !snapshot.isIdle, hasProbeableWindow: hasProbeableWindow, atMs: nowMs)
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
    ) -> WebPage<AXUIElement>? {
        switch mode {
        case .off:
            return nil
        case .probing where !pageReading.isProbeDue(app: app, pid: pid, window: window, atMs: nowMs):
            return nil
        case .on, .probing:
            electronTree.enableIfElectron(app: appElement, pid: pid, bundlePath: bundlePath)
            let pages = PageSearch.contentPages(in: window, bundlePath: bundlePath)
            if mode == .probing {
                pageReading.noteProbe(app: app, pid: pid, window: window, hasContentPages: !pages.isEmpty, atMs: nowMs)
            }
            return PageSearch.choose(from: pages, app: appElement, bundlePath: bundlePath)
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
        snapshot.documentPath = window.string(kAXDocumentAttribute).map(Self.documentPath(fromAXDocument:))
        return window
    }

    /// AXDocument is a URL string, usually file://. File URLs are stored as plain paths.
    static func documentPath(fromAXDocument doc: String) -> String {
        if let url = URL(string: doc), url.isFileURL {
            return url.path
        }
        else {
            return doc
        }
    }
}
