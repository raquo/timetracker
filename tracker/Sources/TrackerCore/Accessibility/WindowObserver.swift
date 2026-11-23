import ApplicationServices
import Foundation

/// Fires when something in the frontmost app changes that a sample would see: its focused
/// window, that window's title (e.g. switching browser tabs), and for apps whose pages are read the
/// keyboard focus and the shown page. So the tracker doesn't need a fast poll to catch them.
///
/// Confined to the tracker's queue. macOS delivers notifications on the main run loop;
/// the observer hops to the queue before touching its state or calling `onChange`.
final class WindowObserver {
    /// Called on the queue. Set once, before the first `observe`.
    var onChange: (() -> Void)?

    private let queue: DispatchQueue
    private var observer: AXObserver?
    private var pid: pid_t?
    private var isWatchingFocusedElement = false
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var pageElement: AXUIElement?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Follow the app with this pid (nil: stop observing). Cheap to call on every tick.
    /// `watchFocusedElement` also fires on keyboard focus moving inside the app: for apps whose
    /// window title doesn't change when their content does (e.g. Claude switching conversations).
    func observe(pid: pid_t?, watchFocusedElement: Bool, isAxTrusted: Bool) {
        if pid == self.pid, watchFocusedElement == isWatchingFocusedElement, observer != nil {
            refreshWindow()
            return
        }
        stop()
        guard let pid, isAxTrusted else {
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, windowObserverCallback, &created) == .success, let created else {
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(created, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        if watchFocusedElement {
            AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        self.pid = pid
        isWatchingFocusedElement = watchFocusedElement
        appElement = app
        refreshWindow()
    }

    /// Also watches this web page element for title changes and loads, for apps whose window
    /// title stays the same while the page changes. nil: stop watching.
    func watchPage(_ page: AXUIElement?) {
        guard let observer else {
            return
        }
        if let old = pageElement, old == page {
            return
        }
        if let old = pageElement {
            AXObserverRemoveNotification(observer, old, kAXTitleChangedNotification as CFString)
            AXObserverRemoveNotification(observer, old, AXName.loadCompleteNotification as CFString)
        }
        pageElement = page
        if let page {
            AXObserverAddNotification(observer, page, kAXTitleChangedNotification as CFString, refcon)
            AXObserverAddNotification(observer, page, AXName.loadCompleteNotification as CFString, refcon)
        }
    }

    /// Releasing the observer removes all its notifications.
    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        pid = nil
        isWatchingFocusedElement = false
        appElement = nil
        windowElement = nil
        pageElement = nil
    }

    /// Moves the title subscription to the currently focused window, if it changed.
    private func refreshWindow() {
        guard let observer, let appElement else {
            return
        }
        let focused = appElement.focusedWindow
        if let old = windowElement, old == focused {
            return
        }
        if let old = windowElement {
            AXObserverRemoveNotification(observer, old, kAXTitleChangedNotification as CFString)
        }
        windowElement = focused
        if let focused {
            AXObserverAddNotification(observer, focused, kAXTitleChangedNotification as CFString, refcon)
        }
    }

    /// Called on the main run loop.
    fileprivate func received(_ notification: String) {
        let isFocusedWindowChange = notification == kAXFocusedWindowChangedNotification
        queue.async { [self] in
            if isFocusedWindowChange {
                refreshWindow()
            }
            onChange?()
        }
    }

    // Unretained: the tracker keeps this object alive for the life of the process.
    private var refcon: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

private func windowObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }
    Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue().received(notification as String)
}
