import ApplicationServices
import Foundation
@testable import TrackerCore

/// A hand-built Accessibility element, for running `PageSearch` without a live app.
/// `==` is identity, like `CFEqual` on live elements.
final class FakeNode: AccessibilityNode, CustomStringConvertible {
    var attributes: [String: String]
    private(set) var children: [FakeNode] = []
    private(set) weak var parentNode: FakeNode?
    /// The app element's keyboard focus (`kAXFocusedUIElementAttribute`).
    weak var focused: FakeNode?

    init(_ role: String, _ attributes: [String: String] = [:], _ children: [FakeNode] = []) {
        self.attributes = attributes
        self.attributes[kAXRoleAttribute] = role
        for child in children {
            add(child)
        }
    }

    /// A web area showing `url`, titled `title`.
    static func webArea(_ url: String, title: String? = nil, _ children: [FakeNode] = []) -> FakeNode {
        var attributes = [AXName.url: url]
        attributes[kAXTitleAttribute] = title
        return FakeNode(AXName.webAreaRole, attributes, children)
    }

    func add(_ child: FakeNode) {
        children.append(child)
        child.parentNode = self
    }

    static func == (a: FakeNode, b: FakeNode) -> Bool {
        a === b
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func string(_ attribute: String) -> String? {
        attributes[attribute].flatMap { $0.isEmpty ? nil : $0 }
    }

    func url(_ attribute: String) -> URL? {
        attributes[attribute].flatMap(URL.init(string:))
    }

    func element(_ attribute: String) -> FakeNode? {
        switch attribute {
        case kAXParentAttribute: parentNode
        case kAXFocusedUIElementAttribute: focused
        default: nil
        }
    }

    func elements(_ attribute: String) -> [FakeNode] {
        attribute == kAXChildrenAttribute ? children : []
    }

    var description: String {
        "\(attributes[kAXRoleAttribute] ?? "?") \(attributes[AXName.url] ?? "")"
    }
}
