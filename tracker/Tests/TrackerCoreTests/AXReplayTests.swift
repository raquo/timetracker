import ApplicationServices
import Foundation
import Testing
@testable import TrackerCore

/// Recorded Accessibility trees (`Fixtures/ax/`, see its README), replayed on `FakeNode`s.
struct AXReplayTests {
    /// What the tracker records from each fixture: the window's attributes and the chosen page.
    /// App fields (bundle ID, name, paths) come from `NSWorkspace`, not the tree, so they're left out.
    static let expected: [String: Snapshot] = [
        // Chrome reports the tab's URL as the window's document too, scrubbed like page URLs.
        "chrome-example-page": window(
            "Example Domain - Google Chrome - Work",
            documentPath: "https://example.com/",
            url: "https://example.com/",
            pageTitle: "Example Domain"
        ),
        // Firefox (Developer Edition): the page title is in the description, no document.
        "firefox-example-page": window("Example Domain", url: "https://example.com/", pageTitle: "Example Domain"),
        // Claude: its own UI page (inside the bundle) isn't content; the claude.ai page is.
        "claude-chat": window(
            "Claude",
            url: "https://claude.ai/chat/00000000-0000-0000-0000-000000000000",
            pageTitle: "Greeting - Claude"
        ),
        "claude-code-session": window(
            "Claude",
            url: "https://claude.ai/epitaxy/local_00000000-0000-0000-0000-000000000000",
            pageTitle: "Tracking testing strategy - Claude Code"
        ),
        // Known gap: a chat opened in its own window (⌘-click) reports its page as about:blank,
        // titled right. about:blank isn't content, so only the window title is recorded.
        "claude-cmd-click-window": window("Greeting"),
        // A browser's own page counts, DevTools too. The URL nested in `remoteBase` has nothing to scrub.
        "chrome-devtools": window(
            "DevTools - example.com/ - Work",
            documentPath: devTools,
            url: devTools,
            pageTitle: "DevTools"
        ),
        // Its one page is an about:blank placeholder: no page.
        "firefox-picture-in-picture": window("Picture-in-Picture"),
        // Nothing holds focus, but there's only one page.
        "notion-page": window(
            "Hello world page",
            url: "https://app.notion.com/p/Hello-world-page-00000000000000000000000000000000",
            pageTitle: "Hello world page"
        ),
        // Native apps: no pages. A file's document URL becomes a plain path, decoded.
        "preview-image": window("make time.png", documentPath: "/Users/someone/Desktop/Meme Hall of Fame/make time.png"),
        "textedit-unsaved-document": window("Untitled 10"),
    ]

    private static let devTools = "devtools://devtools/bundled/devtools_app.html?remoteBase=https://chrome-devtools-frontend.appspot.com/serve_file/@1de57fa19722fa6d6841d4f596c394d015580656/&targetType=tab&can_dock=true"

    /// A normal window: standard, main, not full screen.
    private static func window(_ title: String, documentPath: String? = nil, url: String? = nil, pageTitle: String? = nil) -> Snapshot {
        Snapshot(
            windowTitle: title,
            windowRole: kAXWindowRole,
            windowSubrole: kAXStandardWindowSubrole,
            isMainWindow: true,
            isFullScreen: false,
            documentPath: documentPath,
            url: url,
            pageTitle: pageTitle
        )
    }

    @Test(arguments: AXFixtures.names)
    func replayFindsWhatTheLiveSearchFound(name: String) throws {
        let fixture = try AXFixtures.load(name)
        let replay = Replay(fixture)
        #expect(AXFixture.search(app: replay.app, window: replay.window, bundlePath: fixture.bundlePath) == fixture.live)
    }

    @Test(arguments: AXFixtures.names)
    func recordsTheExpectedSnapshot(name: String) throws {
        let fixture = try AXFixtures.load(name)
        let expected = try #require(Self.expected[name], "Write the expected snapshot for \(name) in AXReplayTests.expected")
        #expect(Self.snapshot(Replay(fixture), bundlePath: fixture.bundlePath) == expected)
    }

    /// What `Sampler` reads from the tree, for an app whose pages are read.
    static func snapshot(_ replay: Replay, bundlePath: String?) -> Snapshot {
        var snapshot = Snapshot()
        if let window = Sampler.readFocusedWindow(of: replay.app, into: &snapshot) {
            let page = PageSearch.choose(from: PageSearch.contentPages(in: window, bundlePath: bundlePath), app: replay.app)
            snapshot.url = page?.url
            snapshot.pageTitle = page?.title
        }
        return snapshot
    }
}

/// `AXFixture.capture` on hand-built trees: what it records, and that the replay behaves the same.
struct AXFixtureCaptureTests {
    private let bundlePath = "/Applications/Browser.app"

    /// A browser window with two pages side by side. The right one holds an iframe holding a
    /// text area; the toolbar holds the address bar and a tab strip page. Nodes that aren't web
    /// areas carry titles and values, which must not be recorded.
    private func browser() -> (app: FakeNode, window: FakeNode, left: FakeNode, right: FakeNode, iframeField: FakeNode, addressBar: FakeNode) {
        let iframeField = FakeNode(kAXTextAreaRole, [kAXValueAttribute: "typed text"])
        let iframe = FakeNode.webArea("https://docs.example.com/frame", title: "Frame", [FakeNode(kAXGroupRole, [:], [iframeField])])
        let right = FakeNode.webArea("https://b.example.com/doc?token=abc#h", title: "B", [
            FakeNode(kAXStaticTextRole, [kAXValueAttribute: "page text"]),
            FakeNode(kAXGroupRole, [:], [FakeNode(kAXButtonRole, [kAXTitleAttribute: "Share"]), iframe]),
        ])
        let left = FakeNode.webArea("https://a.example.com/", title: "A", [FakeNode(kAXStaticTextRole, [kAXValueAttribute: "left text"])])
        left.attributes[kAXValueAttribute] = "page value"
        left.attributes[AXName.domIdentifier] = "page-id"
        let addressBar = FakeNode(kAXTextFieldRole, [kAXValueAttribute: "a.example.com"])
        let toolbar = FakeNode(kAXToolbarRole, [:], [addressBar, FakeNode.webArea("https://tabstrip.example.com/")])
        let split = FakeNode(kAXSplitGroupRole, [kAXDescriptionAttribute: "Split view"], [left, right])
        let window = FakeNode(kAXWindowRole, [kAXTitleAttribute: "B - Browser", kAXSubroleAttribute: kAXStandardWindowSubrole, kAXDocumentAttribute: "https://b.example.com/doc?token=abc#h"], [toolbar, split])
        window.flags = [kAXMainAttribute: true, AXName.fullScreen: false]
        let app = FakeNode(kAXApplicationRole, [:], [window])
        app.focusedWindow = window
        app.focused = iframeField
        return (app, window, left, right, iframeField, addressBar)
    }

    private func roundTrip(_ fixture: AXFixture) throws -> AXFixture {
        try AXFixture.decode(fixture.encoded())
    }

    private func strings(_ pairs: [String: String]) -> [String: AXFixture.Attribute] {
        pairs.mapValues { .string($0) }
    }

    @Test func recordsWhatTheTrackerReadsAndNoMore() throws {
        let b = browser()
        let fixture = try roundTrip(AXFixture.capture(app: b.app, window: b.window, bundleID: "com.example.Browser", bundlePath: bundlePath))
        typealias Node = AXFixture.Node
        let iframeBranch = Node(attributes: strings([kAXRoleAttribute: kAXGroupRole]), children: [
            Node(attributes: strings([kAXRoleAttribute: AXName.webAreaRole, AXName.url: "https://docs.example.com/frame", kAXTitleAttribute: "Frame"]), children: [
                Node(attributes: strings([kAXRoleAttribute: kAXGroupRole]), children: [
                    Node(attributes: strings([kAXRoleAttribute: kAXTextAreaRole])),
                ]),
            ]),
        ], isTrimmed: true)
        var windowAttributes = strings([
            kAXRoleAttribute: kAXWindowRole,
            kAXSubroleAttribute: kAXStandardWindowSubrole,
            kAXTitleAttribute: "B - Browser",
            kAXDocumentAttribute: "https://b.example.com/doc?token=abc#h",
        ])
        windowAttributes[kAXMainAttribute] = .bool(true)
        windowAttributes[AXName.fullScreen] = .bool(false)
        let expected = AXFixture(
            bundleID: "com.example.Browser",
            bundlePath: bundlePath,
            window: Node(attributes: windowAttributes, children: [
                // Not descended into: the address bar isn't on the way to the focus.
                Node(attributes: strings([kAXRoleAttribute: kAXToolbarRole]), isTrimmed: true),
                Node(attributes: strings([kAXRoleAttribute: kAXSplitGroupRole]), children: [
                    Node(attributes: strings([kAXRoleAttribute: AXName.webAreaRole, AXName.url: "https://a.example.com/", kAXTitleAttribute: "A"]), isTrimmed: true),
                    // Within a page only the branch to the focus: not the page text, not the button.
                    Node(attributes: strings([kAXRoleAttribute: AXName.webAreaRole, AXName.url: "https://b.example.com/doc?token=abc#h", kAXTitleAttribute: "B"]), children: [iframeBranch], isTrimmed: true),
                ]),
            ]),
            focusPath: [1, 1, 0, 0, 0, 0],
            live: AXFixture.SearchResult(
                visited: 5,
                pages: [AXFixture.Page(url: "https://a.example.com/", title: "A"), AXFixture.Page(url: "https://b.example.com/doc?token=REDACTED", title: "B")],
                chosen: 1
            )
        )
        #expect(fixture == expected)
    }

    @Test func replayBehavesLikeTheOriginal() throws {
        let b = browser()
        let fixture = try roundTrip(AXFixture.capture(app: b.app, window: b.window, bundleID: "com.example.Browser", bundlePath: bundlePath))
        let replay = Replay(fixture)
        #expect(replay.focused?.role == kAXTextAreaRole)
        #expect(AXFixture.search(app: replay.app, window: replay.window, bundlePath: bundlePath) == fixture.live)
        var original = Snapshot()
        _ = Sampler.readFocusedWindow(of: b.app, into: &original)
        original.url = "https://b.example.com/doc?token=REDACTED"
        original.pageTitle = "B"
        #expect(AXReplayTests.snapshot(replay, bundlePath: bundlePath) == original)
        #expect(original == Snapshot(
            windowTitle: "B - Browser",
            windowRole: kAXWindowRole,
            windowSubrole: kAXStandardWindowSubrole,
            isMainWindow: true,
            isFullScreen: false,
            documentPath: "https://b.example.com/doc?token=REDACTED",
            url: "https://b.example.com/doc?token=REDACTED",
            pageTitle: "B"
        ))
    }

    @Test func focusInTheToolbarIsRecorded() throws {
        let b = browser()
        b.app.focused = b.addressBar
        let fixture = try roundTrip(AXFixture.capture(app: b.app, window: b.window, bundleID: "com.example.Browser", bundlePath: bundlePath))
        #expect(fixture.focusPath == [0, 0])
        #expect(fixture.window.children?[0].children?.count == 1)
        // Split view with the focus outside both pages: rather no page than the wrong one.
        #expect(fixture.live.chosen == nil)
        let replay = Replay(fixture)
        #expect(replay.focused?.role == kAXTextFieldRole)
        #expect(AXFixture.search(app: replay.app, window: replay.window, bundlePath: bundlePath) == fixture.live)
    }

    @Test func focusOutsideTheWindowIsNotRecorded() throws {
        let b = browser()
        let otherWindow = FakeNode(kAXWindowRole, [:], [FakeNode(kAXTextFieldRole)])
        b.app.add(otherWindow)
        b.app.focused = otherWindow.children[0]
        let fixture = try roundTrip(AXFixture.capture(app: b.app, window: b.window, bundleID: "com.example.Browser", bundlePath: bundlePath))
        #expect(fixture.focusPath == nil)
        #expect(Replay(fixture).focused == nil)
        b.app.focused = nil
        #expect(try roundTrip(AXFixture.capture(app: b.app, window: b.window, bundleID: "com.example.Browser", bundlePath: bundlePath)).focusPath == nil)
    }

    /// Past `maxNodes` nothing more is recorded, but the search's budget ends well before that,
    /// so the replay still visits the same elements.
    @Test func hugeTreeIsCutAtMaxNodes() throws {
        let groups = (0..<(AXFixture.maxNodes + 500)).map { _ in FakeNode(kAXGroupRole) }
        let window = FakeNode(kAXWindowRole, [:], groups + [FakeNode.webArea("https://example.com/")])
        let app = FakeNode(kAXApplicationRole, [:], [window])
        app.focusedWindow = window
        let fixture = try roundTrip(AXFixture.capture(app: app, window: window, bundleID: "com.example.Big", bundlePath: nil))
        #expect(fixture.window.children?.count == AXFixture.maxNodes - 1)
        #expect(fixture.window.isTrimmed == true)
        #expect(fixture.live == AXFixture.SearchResult(visited: PageSearch.budget, pages: [], chosen: nil))
        let replay = Replay(fixture)
        #expect(AXFixture.search(app: replay.app, window: replay.window, bundlePath: nil) == fixture.live)
    }
}
