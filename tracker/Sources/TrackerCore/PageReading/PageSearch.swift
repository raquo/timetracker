import ApplicationServices
import Foundation

/// A web page shown in an app's window: its `AXWebArea` element, and that element's URL and title.
struct WebPage<Node: AccessibilityNode> where Node.Element == Node {
    let element: Node
    let url: String
    let title: String?
}

/// Finds the content pages in a window's Accessibility tree (`AXWebArea` elements), and picks
/// the one in use. Only reads the tree, so it runs the same on live `AXUIElement`s and on
/// recorded trees. Which apps to search, and when, is up to `PageReadingPolicy`; Electron apps
/// need their tree switched on first (`ElectronTreeSwitch`).
enum PageSearch {
    /// Max elements to visit when searching a window for web areas. We never descend into a
    /// web area or a toolbar (a browser's tab strip), so this only covers the app's own UI
    /// around the pages: Firefox 16, Claude 20, Safari 22, Chrome 56. Mainly caps the cost of
    /// searching apps without pages.
    static let budget = 150
    static let maxParentHops = 100

    /// The content pages shown in `window`. Searches afresh on every call, so it never reports
    /// a page that's no longer shown.
    static func contentPages<Node: AccessibilityNode>(in window: Node, bundlePath: String?) -> [WebPage<Node>] where Node.Element == Node {
        webAreas(in: window).webAreas.compactMap { contentPage($0, bundlePath: bundlePath) }
    }

    /// The page in use among `pages`, or nil when there is none, or several and we can't tell
    /// which one is in use (consistency: rather no URL than the wrong one). `app`: the app
    /// element, to find the keyboard focus.
    static func choose<Node: AccessibilityNode>(from pages: [WebPage<Node>], app: Node) -> WebPage<Node>? where Node.Element == Node {
        if pages.count == 1 {
            return pages[0]
        }
        else if pages.count > 1 {
            // Several pages (e.g. split view): use the one holding keyboard focus.
            return pageHoldingFocus(pages, app: app)
        }
        else {
            return nil
        }
    }

    /// All web areas in `window`, content or not, and how many elements the search visited.
    static func webAreas<Node: AccessibilityNode>(in window: Node) -> (visited: Int, webAreas: [Node]) where Node.Element == Node {
        var webAreas: [Node] = []
        var remaining = budget
        collectWebAreas(window, budget: &remaining, into: &webAreas)
        return (budget - remaining, webAreas)
    }

    private static func collectWebAreas<Node: AccessibilityNode>(_ element: Node, budget: inout Int, into result: inout [Node]) where Node.Element == Node {
        guard budget > 0 else {
            return
        }
        budget -= 1
        let role = element.role
        if role == AxName.webAreaRole {
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

    /// The page shown by `webArea`, if it is content rather than the app's own UI.
    private static func contentPage<Node: AccessibilityNode>(_ webArea: Node, bundlePath: String?) -> WebPage<Node>? where Node.Element == Node {
        guard let url = webArea.url(AxName.url), isContent(url, bundlePath: bundlePath), let scrubbed = UrlScrubber.scrub(url) else {
            return nil
        }
        // Firefox and Safari leave the title empty and put it in the description.
        let title = webArea.string(kAXTitleAttribute) ?? webArea.string(kAXDescriptionAttribute)
        return WebPage(element: webArea, url: scrubbed, title: title)
    }

    /// Every page counts except two that are certainly not content (see "Record raw data
    /// generously" in docs/tracker-principles.md):
    /// - pages loaded from the app's own bundle, whatever the scheme: its UI (Electron's
    ///   `file://…/Claude.app/…/app.asar/…`, VS Code's `vscode-file://vscode-app/…/Visual Studio Code.app/…`);
    /// - `about:blank`, an empty placeholder (Firefox's Picture-in-Picture player).
    /// So browsers' own pages count (`chrome://new-tab-page/`, `about:newtab`, `about:preferences`),
    /// and so do app-private schemes outside the bundle (Obsidian's `app://obsidian.md/…`).
    static func isContent(_ url: URL, bundlePath: String?) -> Bool {
        let address = url.absoluteString.prefix { $0 != "?" && $0 != "#" }.lowercased()
        if address.isEmpty || address == "about:blank" {
            return false
        }
        else if let bundlePath, url.scheme != "http", url.scheme != "https", url.path.hasPrefix(bundlePath + "/") {
            return false
        }
        else {
            return true
        }
    }

    /// The page among `pages` that holds keyboard focus, found by walking up from the focused
    /// element. Walks past other web areas on the way: focus is often in an iframe within the
    /// page (Google Docs types into one), and an iframe is a web area of its own.
    private static func pageHoldingFocus<Node: AccessibilityNode>(_ pages: [WebPage<Node>], app: Node) -> WebPage<Node>? where Node.Element == Node {
        var element = app.focusedUiElement
        for _ in 0..<maxParentHops {
            guard let current = element else {
                return nil
            }
            if let page = pages.first(where: { $0.element == current }) {
                return page
            }
            element = current.parent
        }
        return nil
    }
}
