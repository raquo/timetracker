import ApplicationServices
import Testing
@testable import TrackerCore

/// `PageSearch` on hand-built trees: which pages are found, and which one is chosen.
struct PageSearchTests {
    private let bundlePath = "/Applications/Browser.app"

    /// A window with a toolbar (holding a web area, like a browser's tab strip) and the given
    /// pages side by side.
    private func window(_ pages: [FakeNode], toolbar: FakeNode = FakeNode(kAXToolbarRole)) -> FakeNode {
        FakeNode(kAXWindowRole, [:], [toolbar, FakeNode(kAXSplitGroupRole, [:], pages)])
    }

    private func app(_ window: FakeNode, focus: FakeNode?) -> FakeNode {
        let app = FakeNode(kAXApplicationRole, [:], [window])
        app.focused = focus
        return app
    }

    @Test func findsContentPagesOnly() {
        let iframe = FakeNode.webArea("https://embed.example.com/player")
        let toolbar = FakeNode(kAXToolbarRole, [:], [FakeNode.webArea("https://tabstrip.example.com/")])
        let pages = [
            FakeNode.webArea("https://a.example.com/doc?token=t#part", title: "A", [FakeNode(kAXGroupRole, [:], [iframe])]),
            FakeNode.webArea("about:blank"),
            FakeNode.webArea("file://\(bundlePath)/Contents/Resources/ui.html"),
            FakeNode(AXName.webAreaRole, [AXName.url: "https://b.example.com/", kAXDescriptionAttribute: "B"]),
        ]
        let found = PageSearch.contentPages(in: window(pages, toolbar: toolbar), bundlePath: bundlePath)
        // Not the toolbar's web area, not the iframe within a page, not the two that aren't
        // content. The URL is scrubbed; the title falls back to the description.
        #expect(found.map(\.url) == ["https://a.example.com/doc?token=REDACTED", "https://b.example.com/"])
        #expect(found.map(\.title) == ["A", "B"])
        #expect(found.map(\.element) == [pages[0], pages[3]])
    }

    @Test func onePageIsChosenWhereverTheFocusIs() {
        let page = FakeNode.webArea("https://a.example.com/")
        let toolbarField = FakeNode(kAXTextFieldRole)
        let w = window([page], toolbar: FakeNode(kAXToolbarRole, [:], [toolbarField]))
        let pages = PageSearch.contentPages(in: w, bundlePath: nil)
        #expect(PageSearch.choose(from: pages, app: app(w, focus: toolbarField))?.element == page)
        #expect(PageSearch.choose(from: pages, app: app(w, focus: nil))?.element == page)
    }

    @Test func noPagesChoosesNothing() {
        let w = window([])
        #expect(PageSearch.choose(from: PageSearch.contentPages(in: w, bundlePath: nil), app: app(w, focus: nil)) == nil)
    }

    /// Split view: two pages. `focus` picks which of the right page's descendants holds focus.
    private func splitView() -> (window: FakeNode, left: FakeNode, right: FakeNode, field: FakeNode, iframeField: FakeNode, addressBar: FakeNode) {
        let field = FakeNode(kAXTextFieldRole)
        let iframeField = FakeNode(kAXTextAreaRole)
        // Google Docs types into an iframe: a web area of its own, within the page.
        let iframe = FakeNode.webArea("https://docs.example.com/texteventtarget", [iframeField])
        let left = FakeNode.webArea("https://a.example.com/", title: "A")
        let right = FakeNode.webArea("https://b.example.com/", title: "B", [FakeNode(kAXGroupRole, [:], [field, iframe])])
        let addressBar = FakeNode(kAXTextFieldRole)
        let w = window([left, right], toolbar: FakeNode(kAXToolbarRole, [:], [addressBar]))
        return (w, left, right, field, iframeField, addressBar)
    }

    @Test func splitViewChoosesThePageHoldingFocus() {
        let s = splitView()
        let pages = PageSearch.contentPages(in: s.window, bundlePath: nil)
        #expect(pages.map(\.element) == [s.left, s.right])
        #expect(PageSearch.choose(from: pages, app: app(s.window, focus: s.left))?.element == s.left)
        #expect(PageSearch.choose(from: pages, app: app(s.window, focus: s.field))?.element == s.right)
    }

    @Test func splitViewLooksPastAnIframeHoldingFocus() {
        let s = splitView()
        let pages = PageSearch.contentPages(in: s.window, bundlePath: nil)
        let chosen = PageSearch.choose(from: pages, app: app(s.window, focus: s.iframeField))
        #expect(chosen?.element == s.right)
        #expect(chosen?.url == "https://b.example.com/")
    }

    @Test func splitViewWithFocusOutsideThePagesChoosesNothing() {
        let s = splitView()
        let pages = PageSearch.contentPages(in: s.window, bundlePath: nil)
        // Rather no URL than the wrong one.
        #expect(PageSearch.choose(from: pages, app: app(s.window, focus: s.addressBar)) == nil)
        #expect(PageSearch.choose(from: pages, app: app(s.window, focus: nil)) == nil)
    }
}
