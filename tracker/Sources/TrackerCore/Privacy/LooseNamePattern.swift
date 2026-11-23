import Foundation

/// Matches names loosely, for scrubbing: one rule covers every spelling of a name, since
/// missing a variant leaks data and an extra match only redacts a little.
///
/// Names and rules are compared after `normalize`: percent-decoded, lowercased, and stripped of
/// everything but letters and digits. So `access_key`, `access-key`, `accessKey`, `AccessKey`,
/// `ACCESS_KEY`, `access.key`, `access%5Fkey` and `accesskey` are all `accesskey`.
///
/// A bracketed name (form fields, Rails and PHP: `user[login]`, `user%5Blogin%5D`) also matches
/// if its innermost key does (`login`), since that's the field's own name.
struct LooseNamePattern {
    /// Normalized names matched whole.
    let exact: Set<String>
    /// Normalized parts matched anywhere in the name.
    let containing: [String]

    /// Rules in any spelling; they're normalized here.
    init(exact: [String], containing: [String]) {
        self.exact = Set(exact.map(Self.normalize))
        self.containing = Array(Set(containing.map(Self.normalize))).sorted()
    }

    func matches(_ name: String) -> Bool {
        if matchesWhole(name) {
            return true
        }
        else if let key = Self.innermostKey(name) {
            return matchesWhole(key)
        }
        else {
            return false
        }
    }

    private func matchesWhole(_ name: String) -> Bool {
        let normalized = Self.normalize(name)
        return exact.contains(normalized) || containing.contains { normalized.contains($0) }
    }

    /// `a[b][c]` → `c`, percent-decoded first. nil without a trailing bracketed key.
    static func innermostKey(_ name: String) -> String? {
        let decoded = name.removingPercentEncoding ?? name
        guard decoded.hasSuffix("]"), let open = decoded.lastIndex(of: "[") else {
            return nil
        }
        return String(decoded[decoded.index(after: open)..<decoded.index(before: decoded.endIndex)])
    }

    static func normalize(_ name: String) -> String {
        String((name.removingPercentEncoding ?? name).lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
