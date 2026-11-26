import ApplicationServices
import Foundation
@testable import TrackerCore

/// Recorded Accessibility trees (`AXFixture`) in `Fixtures/ax/`, replayed on `FakeNode`s.
enum AXFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ax", isDirectory: true)

    /// File names without `.json`, sorted.
    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }.sorted()
    }()

    static func load(_ name: String) throws -> AXFixture {
        try AXFixture.decode(Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }
}

/// A recorded tree rebuilt from `FakeNode`s: the app element, holding the window (its focused
/// window) and the keyboard focus.
struct Replay {
    let app: FakeNode
    let window: FakeNode
    /// The element holding keyboard focus, nil if none was recorded.
    let focused: FakeNode?

    init(_ fixture: AXFixture) {
        window = Self.node(fixture.window)
        app = FakeNode(kAXApplicationRole, [:], [window])
        app.focusedWindow = window
        var focused: FakeNode? = nil
        if let path = fixture.focusPath {
            focused = window
            for index in path {
                focused = focused?.children[index]
            }
        }
        self.focused = focused
        app.focused = focused
    }

    private static func node(_ n: AXFixture.Node) -> FakeNode {
        var strings: [String: String] = [:]
        var flags: [String: Bool] = [:]
        for (name, attribute) in n.attributes {
            switch attribute {
            case .string(let s):
                strings[name] = s
            case .bool(let b):
                flags[name] = b
            }
        }
        let node = FakeNode(strings[kAXRoleAttribute] ?? "", strings, (n.children ?? []).map(Self.node))
        node.flags = flags
        return node
    }
}
