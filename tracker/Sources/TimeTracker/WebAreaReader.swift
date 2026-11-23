import AppKit
import ApplicationServices

/// A web page shown in an app's window: its `AXWebArea` element, and that element's URL and title.
struct WebPage {
    let element: AXUIElement
    let url: String
    let title: String?
}

/// Reads the web pages shown in an app's window, through the Accessibility tree of its web
/// content (`AXWebArea`). Which apps, and how often, is up to `PageReadingPolicy`.
///
/// Electron apps build their web Accessibility tree only after we switch it on
/// (`AXManualAccessibility`), and then keep it up to date on every page change until they quit,
/// which has a cost. Browsers and native apps with web views expose their pages without a switch.
/// See notes/electron-and-claude.md.
///
/// We never switch the tree back off: we can't tell whether something else started relying on
/// it while we ran (see TODO "Tracker: Accessibility tree in other apps" in notes/PLAN.md).
/// It goes off when the app quits.
///
/// Confined to the tracker's queue.
final class WebAreaReader {
    /// Max elements to visit when searching a window for web areas. We never descend into a
    /// web area or a toolbar (a browser's tab strip), so this only covers the app's own UI
    /// around the pages: Firefox 16, Claude 20, Safari 22, Chrome 56. Mainly caps the cost of
    /// searching apps without pages.
    private static let searchBudget = 150
    private static let maxParentHops = 100

    /// Apps whose tree we've switched on this run.
    private var enabledPIDs: Set<pid_t> = []
    /// Whether the bundle at each path is an Electron app.
    private var electronBundles: [String: Bool] = [:]

    /// The content pages shown in `window`. Searches the window afresh on every call, so it
    /// never reports a page that's no longer shown. Switches an Electron app's tree on first;
    /// it's built asynchronously, so the first calls after that may find nothing.
    func pages(app: AXUIElement, pid: pid_t, bundlePath: String?, window: AXUIElement) -> [WebPage] {
        if isElectron(bundlePath: bundlePath) {
            enableTree(app: app, pid: pid)
        }
        return search(window).webAreas.compactMap { Self.contentPage($0, bundlePath: bundlePath) }
    }

    /// The page in use among `pages`, or nil when there is none, or several and we can't tell
    /// which one is in use (consistency: rather no URL than the wrong one).
    func choose(from pages: [WebPage], app: AXUIElement, bundlePath: String?) -> WebPage? {
        if pages.count == 1 {
            return pages[0]
        }
        else if pages.count > 1, let focused = focusedWebArea(app: app, bundlePath: bundlePath) {
            // Several pages (e.g. split view): use the one holding keyboard focus.
            return pages.first { CFEqual($0.element, focused) }
        }
        else {
            return nil
        }
    }

    /// Diagnostics: runs the same search as `pages(...)` on `window`, and reports how many
    /// elements it visited and which web areas it found.
    func measureSearch(window: AXUIElement) -> (visited: Int, webAreas: [AXUIElement]) {
        search(window)
    }

    private func enableTree(app: AXUIElement, pid: pid_t) {
        guard !enabledPIDs.contains(pid) else {
            return
        }
        // Prune apps that quit (pids can be reused).
        enabledPIDs = enabledPIDs.filter { NSRunningApplication(processIdentifier: $0) != nil }
        let result = app.set(AXName.manualAccessibility, true)
        if result == .success {
            enabledPIDs.insert(pid)
            log.info("Enabled Accessibility tree for pid \(pid)")
        }
        else {
            log.warning("Could not enable Accessibility tree for pid \(pid): \(result.rawValue)")
        }
    }

    /// Electron apps ship `Electron Framework.framework`, whatever they're called.
    private func isElectron(bundlePath: String?) -> Bool {
        guard let bundlePath else {
            return false
        }
        if let cached = electronBundles[bundlePath] {
            return cached
        }
        let framework = bundlePath + "/Contents/Frameworks/Electron Framework.framework"
        let isElectron = FileManager.default.fileExists(atPath: framework)
        electronBundles[bundlePath] = isElectron
        return isElectron
    }

    /// The page shown by `webArea`, if it is content rather than the app's own UI.
    private static func contentPage(_ webArea: AXUIElement, bundlePath: String?) -> WebPage? {
        guard let url = webArea.url(AXName.url), isContent(url, bundlePath: bundlePath), let scrubbed = URLScrubber.scrub(url) else {
            return nil
        }
        // Firefox and Safari leave the title empty and put it in the description.
        let title = webArea.string(kAXTitleAttribute) ?? webArea.string(kAXDescriptionAttribute)
        return WebPage(element: webArea, url: scrubbed, title: title)
    }

    /// Pages loaded from the app's own bundle are its UI, not content: Electron's
    /// `file://…/Claude.app/…/app.asar/…`, VS Code's `vscode-file://vscode-app/…/Visual Studio Code.app/…`.
    /// `about:` pages (`about:blank`) are placeholders. Anything else counts, whatever the scheme.
    private static func isContent(_ url: URL, bundlePath: String?) -> Bool {
        if url.absoluteString.isEmpty || url.scheme == "about" {
            return false
        }
        else if let bundlePath, url.scheme != "http", url.scheme != "https", url.path.hasPrefix(bundlePath + "/") {
            return false
        }
        else {
            return true
        }
    }

    private func search(_ window: AXUIElement) -> (visited: Int, webAreas: [AXUIElement]) {
        var webAreas: [AXUIElement] = []
        var budget = Self.searchBudget
        collectWebAreas(window, budget: &budget, into: &webAreas)
        return (Self.searchBudget - budget, webAreas)
    }

    private func collectWebAreas(_ element: AXUIElement, budget: inout Int, into result: inout [AXUIElement]) {
        guard budget > 0 else {
            return
        }
        budget -= 1
        let role = element.role
        if role == AXName.webAreaRole {
            result.append(element)
            return
        }
        else if role == kAXToolbarRole {
            return
        }
        for child in element.children {
            collectWebAreas(child, budget: &budget, into: &result)
        }
    }

    /// The content web area that holds keyboard focus, found by walking up from the focused element.
    private func focusedWebArea(app: AXUIElement, bundlePath: String?) -> AXUIElement? {
        var element = app.element(kAXFocusedUIElementAttribute)
        for _ in 0..<Self.maxParentHops {
            guard let current = element else {
                return nil
            }
            if current.role == AXName.webAreaRole, Self.contentPage(current, bundlePath: bundlePath) != nil {
                return current
            }
            element = current.element(kAXParentAttribute)
        }
        return nil
    }
}
