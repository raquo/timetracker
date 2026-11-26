import ApplicationServices
import Foundation

/// A recorded Accessibility tree: an app's focused window, trimmed to what the tracker reads,
/// and what the tracker's page search found on it live. Written by `--dump-ax … --json` (see
/// `AxDump`), replayed in tests on `FakeNode`s.
///
/// Recorded, and nothing else (labels, values and page text never are):
/// - every element: role and subrole;
/// - the window: title, main, full screen, document;
/// - web areas: URL (as reported, not scrubbed), title, description.
///
/// Trimmed where `PageSearch` stops: the contents of web areas and toolbars, and past
/// `maxNodes` / `maxDepth`. Except the branch down to the element holding keyboard focus, which
/// `PageSearch.choose` walks up from.
struct AxFixture: Codable, Equatable {
    struct Node: Codable, Equatable {
        var attributes: [String: Attribute]
        /// nil: none recorded.
        var children: [Node]?
        /// Some children weren't recorded (see `AxFixture`). nil rather than false, to keep files short.
        var isTrimmed: Bool?
    }

    enum Attribute: Codable, Equatable {
        case string(String)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let b = try? container.decode(Bool.self) {
                self = .bool(b)
            }
            else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s):
                try container.encode(s)
            case .bool(let b):
                try container.encode(b)
            }
        }
    }

    struct Page: Codable, Equatable {
        var url: String
        var title: String?
    }

    /// What `PageSearch` found: elements visited, the content pages, and the index of the one
    /// chosen among them.
    struct SearchResult: Codable, Equatable {
        var visited: Int
        var pages: [Page]
        var chosen: Int?
    }

    var bundleId: String
    var bundlePath: String?
    var window: Node
    /// Child indices from the window down to the element holding keyboard focus. nil: nothing
    /// holds focus, or it's outside this window.
    var focusPath: [Int]?
    var live: SearchResult

    static let maxNodes = 2000
    static let maxDepth = 60

    /// Runs the tracker's page search on `window` of `app`.
    static func search<N: AccessibilityNode>(app: N, window: N, bundlePath: String?) -> SearchResult where N.Element == N {
        let visited = PageSearch.webAreas(in: window).visited
        let pages = PageSearch.contentPages(in: window, bundlePath: bundlePath)
        let chosen = PageSearch.choose(from: pages, app: app)
        return SearchResult(
            visited: visited,
            pages: pages.map { Page(url: $0.url, title: $0.title) },
            chosen: chosen.flatMap { c in pages.firstIndex { $0.element == c.element } }
        )
    }

    /// Records `window` of `app`, searching it first.
    static func capture<N: AccessibilityNode>(app: N, window: N, bundleId: String, bundlePath: String?) -> AxFixture where N.Element == N {
        let live = search(app: app, window: window, bundlePath: bundlePath)
        let chain = focusChain(app: app, window: window)
        var count = 0
        var focusPath: [Int] = []
        let root = node(window, isWindow: true, isWithinCut: false, chain: chain ?? [], depth: 0, count: &count, focusPath: &focusPath)
        return AxFixture(
            bundleId: bundleId,
            bundlePath: bundlePath,
            window: root,
            focusPath: chain == nil ? nil : focusPath,
            live: live
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> AxFixture {
        try JSONDecoder().decode(AxFixture.self, from: data)
    }

    /// The window, then each element down to the one holding focus. nil if nothing holds focus
    /// or walking up from it doesn't reach `window`.
    private static func focusChain<N: AccessibilityNode>(app: N, window: N) -> [N]? where N.Element == N {
        var chain: [N] = []
        var element = app.focusedUiElement
        for _ in 0..<PageSearch.maxParentHops {
            guard let current = element else {
                return nil
            }
            chain.append(current)
            if current == window {
                return chain.reversed()
            }
            element = current.parent
        }
        return nil
    }

    /// `chain[depth]` is `element` when it's on the way to the focused element. `isWithinCut`:
    /// within a web area or toolbar, where only the way to the focused element is recorded.
    private static func node<N: AccessibilityNode>(
        _ element: N,
        isWindow: Bool,
        isWithinCut: Bool,
        chain: [N],
        depth: Int,
        count: inout Int,
        focusPath: inout [Int]
    ) -> Node where N.Element == N {
        count += 1
        let role = element.role
        let isWebArea = role == AxName.webAreaRole
        var attributes: [String: Attribute] = [:]
        var names = [kAXRoleAttribute, kAXSubroleAttribute]
        if isWindow {
            names += [kAXTitleAttribute, kAXDocumentAttribute]
        }
        if isWebArea {
            names += [kAXTitleAttribute, kAXDescriptionAttribute]
        }
        for name in names {
            if let s = element.string(name) {
                attributes[name] = .string(s)
            }
        }
        if isWebArea, let url = element.url(AxName.url) {
            attributes[AxName.url] = .string(url.absoluteString)
        }
        if isWindow {
            for name in [kAXMainAttribute, AxName.fullScreen] {
                if let b = element.bool(name) {
                    attributes[name] = .bool(b)
                }
            }
        }
        let isOnChain = depth < chain.count && chain[depth] == element
        let chainChild = isOnChain && depth + 1 < chain.count ? chain[depth + 1] : nil
        let isCut = isWithinCut || isWebArea || role == kAXToolbarRole || depth >= maxDepth
        var children: [Node] = []
        var isTrimmed = false
        for child in element.children {
            let isChainChild = chainChild.map { $0 == child } ?? false
            if isChainChild || (!isCut && count < maxNodes) {
                if isChainChild {
                    focusPath.append(children.count)
                }
                children.append(node(child, isWindow: false, isWithinCut: isCut, chain: chain, depth: depth + 1, count: &count, focusPath: &focusPath))
            }
            else {
                isTrimmed = true
            }
        }
        return Node(attributes: attributes, children: children.isEmpty ? nil : children, isTrimmed: isTrimmed ? true : nil)
    }
}
