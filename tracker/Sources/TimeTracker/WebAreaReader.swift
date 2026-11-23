import AppKit
import ApplicationServices

/// How to make an app build its web Accessibility tree.
struct WebContentProfile {
    /// Set to true on the app element to switch the tree on. nil: the app exposes it anyway.
    let treeSwitchAttribute: String?

    /// Electron apps. Designed for this; no side effects on window animations.
    static let electron = WebContentProfile(treeSwitchAttribute: AXName.manualAccessibility)

    /// Browsers expose the shown tab's page without a switch. (`AXEnhancedUserInterface` would
    /// expose more, with janky window animations as a side effect; not needed.)
    static let browser = WebContentProfile(treeSwitchAttribute: nil)

    /// Browsers get `.browser`, other apps `.electron`.
    static func forApp(_ bundleID: String) -> WebContentProfile {
        Browsers.bundleIDs.contains(bundleID) ? .browser : .electron
    }
}

/// A web page shown in an app's window: its `AXWebArea` element, and that element's URL and title.
struct WebPage {
    let element: AXUIElement
    let url: String
    let title: String?
}

/// Reads the web page shown in an app's focused window, through the Accessibility tree of its
/// web content (`AXWebArea`).
///
/// Only for allowlisted apps, because it has a cost: Electron apps build their web
/// Accessibility tree only after we switch it on, and then keep it up to date on every page
/// change until they quit. Browsers build theirs once any Accessibility client reads it.
/// See notes/electron-and-claude.md.
///
/// We never switch the tree back off: we can't tell whether something else started relying on
/// it while we ran (see TODO "Tracker: Accessibility tree in other apps" in notes/PLAN.md).
/// It goes off when the app quits.
///
/// Allowlist: the Claude desktop app and the browsers in `Browsers`, plus any apps in
/// `defaults write com.raquo.timetracker.tracker accessibilityTreeApps -array <bundle-id> ...`
/// (restart the tracker afterwards).
///
/// Confined to the tracker's queue.
final class WebAreaReader {
    static let defaultsKey = "accessibilityTreeApps"
    static let builtInApps: Set<String> = Browsers.bundleIDs.union([Claude.bundleID])

    /// Max elements to visit when searching a window for web areas. We never descend into a
    /// web area or a toolbar (a browser's tab strip), so this only covers the app's own UI
    /// around the pages (20 elements in Claude).
    private static let searchBudget = 500
    private static let maxParentHops = 100

    private let allowlist: Set<String>
    /// Apps whose tree we've switched on this run.
    private var enabledPIDs: Set<pid_t> = []

    init() {
        let extraApps = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        allowlist = Self.builtInApps.union(extraApps)
        log.info("Accessibility tree apps: \(self.allowlist.sorted().joined(separator: ", "), privacy: .public)")
    }

    func isEnabled(for bundleID: String?) -> Bool {
        bundleID.map(allowlist.contains) ?? false
    }

    /// The content page shown in `window`, or nil when there is none, or several and we can't
    /// tell which one is in use (consistency: rather no URL than the wrong one).
    ///
    /// Searches the window afresh on every call, so it never reports a page that's no longer
    /// shown. Cheap: in Claude ~44 calls, 4–17 ms, the same while it streams a reply.
    func page(app: AXUIElement, pid: pid_t, bundleID: String, bundlePath: String?, window: AXUIElement) -> WebPage? {
        enableTree(app: app, pid: pid, profile: .forApp(bundleID))
        return choose(from: search(window).webAreas, app: app, bundlePath: bundlePath)
    }

    /// Diagnostics: runs the same search as `page(...)` on `window`, and reports how many
    /// elements it visited and which web areas it found.
    func measureSearch(window: AXUIElement) -> (visited: Int, webAreas: [AXUIElement]) {
        search(window)
    }

    private func choose(from webAreas: [AXUIElement], app: AXUIElement, bundlePath: String?) -> WebPage? {
        let pages = webAreas.compactMap { Self.contentPage($0, bundlePath: bundlePath) }
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

    private func enableTree(app: AXUIElement, pid: pid_t, profile: WebContentProfile) {
        guard let attribute = profile.treeSwitchAttribute, !enabledPIDs.contains(pid) else {
            return
        }
        // Prune apps that quit (pids can be reused).
        enabledPIDs = enabledPIDs.filter { NSRunningApplication(processIdentifier: $0) != nil }
        let result = app.set(attribute, true)
        if result == .success {
            enabledPIDs.insert(pid)
            log.info("Enabled Accessibility tree for pid \(pid)")
        }
        else {
            log.warning("Could not enable Accessibility tree for pid \(pid): \(result.rawValue)")
        }
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
