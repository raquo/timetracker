import Foundation

/// Get-or-create IDs in a lookup table whose key columns are UNIQUE together, with an in-memory cache.
/// Key columns hold '' rather than NULL for "unknown", since NULLs never compare equal.
///
/// Strings are told apart byte for byte, as SQLite does: a title is stored exactly as macOS
/// reported it, whatever was looked up before. Swift's `==` treats canonically equivalent strings
/// as equal ("é" and "e" + U+0301, as in file names), so the cache isn't keyed on `Key`.
final class Lookup<Key: Hashable> {
    /// A bound value, compared as SQLite compares it.
    private enum ExactValue: Hashable {
        case null
        case int(Int64)
        case bytes([UInt8])

        init(_ value: SqlValue) {
            switch value {
            case .null: self = .null
            case .int(let i): self = .int(i)
            case .text(let s): self = .bytes(Array(s.utf8))
            }
        }
    }

    private let db: Database
    private let select: Statement
    private let insert: Statement
    private let bind: (Key) -> [SqlValue]
    private let maxCacheSize = 10_000
    private var cache: [[ExactValue]: Int64] = [:]

    /// `extraColumns`: further columns, set only when a row is created (see `id(for:extra:)`).
    init(
        db: Database,
        table: String,
        keyColumns: [String],
        extraColumns: [String] = [],
        bind: @escaping (Key) -> [SqlValue]
    ) throws {
        let columns = keyColumns + extraColumns
        let condition = keyColumns.map { "\($0) = ?" }.joined(separator: " AND ")
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        self.db = db
        self.bind = bind
        select = try db.prepare("SELECT id FROM \(table) WHERE \(condition)")
        insert = try db.prepare("INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))")
    }

    /// nil when `key` is nil. `extra`: values of the extra columns, used only if the row is new.
    func id(for key: Key?, extra: [SqlValue] = []) throws -> Int64? {
        guard let key else {
            return nil
        }
        let params = bind(key)
        let cacheKey = params.map(ExactValue.init)
        if let cached = cache[cacheKey] {
            return cached
        }
        let id: Int64
        if let existing = try select.value(params)?.int {
            id = existing
        }
        else {
            try insert.run(params + extra)
            id = db.lastInsertRowId
        }
        if cache.count >= maxCacheSize {
            cache.removeAll()
        }
        cache[cacheKey] = id
        return id
    }
}

extension Lookup where Key == String {
    /// A `(id, <column> UNIQUE)` table of strings.
    convenience init(db: Database, table: String, column: String) throws {
        try self.init(db: db, table: table, keyColumns: [column]) { [.text($0)] }
    }
}

/// `tracker_window_role` key.
struct WindowRole: Hashable {
    let role: String
    let subrole: String

    /// nil when neither is known (no focused window, or no Accessibility permission).
    init?(role: String?, subrole: String?) {
        if role == nil && subrole == nil {
            return nil
        }
        self.role = role ?? ""
        self.subrole = subrole ?? ""
    }
}

/// Get-or-create `tracker_app` rows, keyed by (identifier_type, identifier, app_path).
/// Keeps each row's `name` current.
final class AppLookup {
    private struct Key: Hashable {
        let app: AppIdentity
        let appPath: String
    }

    private let lookup: Lookup<Key>
    private let updateName: Statement
    /// Names written or confirmed this run, by row ID.
    private var names: [Int64: String] = [:]

    init(db: Database) throws {
        lookup = try Lookup(
            db: db,
            table: "tracker_app",
            keyColumns: ["identifier_type", "identifier", "app_path"],
            extraColumns: ["name"]
        ) { key in
            [.int(key.app.type.rawValue), .text(key.app.identifier), .text(key.appPath)]
        }
        updateName = try db.prepare("UPDATE tracker_app SET name = ?1 WHERE id = ?2 AND name IS NOT ?1")
    }

    /// nil when `app` is nil. A nil name is derived from the path.
    func id(for app: ProcessApp?) throws -> Int64? {
        guard let app else {
            return nil
        }
        let key = Key(app: app.identity, appPath: app.appPath)
        let name = app.name ?? URL(fileURLWithPath: key.appPath.isEmpty ? key.app.identifier : key.appPath).lastPathComponent
        guard let id = try lookup.id(for: key, extra: [.text(name)]) else {
            return nil
        }
        // Byte for byte, like the lookup.
        if names[id].map({ !$0.utf8.elementsEqual(name.utf8) }) ?? true {
            try updateName.run([.text(name), .int(id)])
            names[id] = name
        }
        return id
    }
}
