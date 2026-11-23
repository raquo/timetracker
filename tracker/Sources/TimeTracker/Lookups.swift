import Foundation

/// Get-or-create IDs in a lookup table whose key columns are UNIQUE together, with an in-memory cache.
/// Key columns hold '' rather than NULL for "unknown", since NULLs never compare equal.
final class Lookup<Key: Hashable> {
    private let db: Database
    private let select: Statement
    private let insert: Statement
    private let bind: (Key) -> [SQLValue]
    private let maxCacheSize = 10_000
    private var cache: [Key: Int64] = [:]

    /// `extraColumns`: further columns, set only when a row is created (see `id(for:extra:)`).
    init(
        db: Database,
        table: String,
        keyColumns: [String],
        extraColumns: [String] = [],
        bind: @escaping (Key) -> [SQLValue]
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
    func id(for key: Key?, extra: [SQLValue] = []) throws -> Int64? {
        guard let key else {
            return nil
        }
        if let cached = cache[key] {
            return cached
        }
        let params = bind(key)
        let id: Int64
        if let existing = try select.run(params).first?.first?.int {
            id = existing
        }
        else {
            try insert.run(params + extra)
            id = db.lastInsertRowID
        }
        if cache.count >= maxCacheSize {
            cache.removeAll()
        }
        cache[key] = id
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

/// `tracker_app.identifier_type`: what `identifier` holds. Stored as its raw value.
enum AppIdentifierType: Int64 {
    case bundleID = 0
    /// For processes without a bundle ID.
    case executablePath = 1
}

/// Get-or-create `tracker_app` rows, keyed by (identifier_type, identifier, app_path).
/// Keeps each row's `name` current.
final class AppLookup {
    private struct Key: Hashable {
        let identifierType: AppIdentifierType
        let identifier: String
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
            [.int(key.identifierType.rawValue), .text(key.identifier), .text(key.appPath)]
        }
        updateName = try db.prepare("UPDATE tracker_app SET name = ?1 WHERE id = ?2 AND name IS NOT ?1")
    }

    /// nil when the snapshot has no app, or macOS gave neither a bundle ID nor an executable path.
    func id(for s: Snapshot) throws -> Int64? {
        guard let key = Self.key(for: s) else {
            return nil
        }
        let name = s.appName ?? URL(fileURLWithPath: key.appPath.isEmpty ? key.identifier : key.appPath).lastPathComponent
        guard let id = try lookup.id(for: key, extra: [.text(name)]) else {
            return nil
        }
        if names[id] != name {
            try updateName.run([.text(name), .int(id)])
            names[id] = name
        }
        return id
    }

    private static func key(for s: Snapshot) -> Key? {
        if let bundleID = s.bundleID, !bundleID.isEmpty {
            return Key(identifierType: .bundleID, identifier: bundleID, appPath: s.bundlePath ?? s.executablePath ?? "")
        }
        else if let executablePath = s.executablePath, !executablePath.isEmpty {
            return Key(identifierType: .executablePath, identifier: executablePath, appPath: s.bundlePath ?? executablePath)
        }
        else {
            return nil
        }
    }
}
