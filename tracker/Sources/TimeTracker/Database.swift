import Foundation
import SQLite3

/// Tells SQLite to copy bound strings, since Swift may free them before the statement runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    let sql: String?

    var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " [\($0)]" } ?? "")
    }
}

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case text(String)

    init(_ value: Int64?) {
        self = value.map(SQLValue.int) ?? .null
    }

    init(_ value: String?) {
        self = value.map(SQLValue.text) ?? .null
    }

    init(_ value: Bool) {
        self = .int(value ? 1 : 0)
    }

    init(_ value: Bool?) {
        self = value.map { .int($0 ? 1 : 0) } ?? .null
    }

    var int: Int64? {
        if case .int(let i) = self {
            return i
        }
        else {
            return nil
        }
    }
}

/// Minimal wrapper over the SQLite C API. Not thread-safe: use from one queue.
final class Database {
    fileprivate let handle: OpaquePointer

    init(path: String) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(h)
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        handle = h
        // The server reads (and writes its own tables in) the same file; wait for its locks instead of failing.
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: message, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(db: self, sql: sql)
    }

    /// Runs `body` in a write transaction. Keep it short: the server waits on it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        }
        catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    fileprivate var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }
}

final class Statement {
    private let db: Database
    private let stmt: OpaquePointer
    private let sql: String

    fileprivate init(db: Database, sql: String) throws {
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.handle, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s else {
            throw SQLiteError(code: rc, message: db.errorMessage, sql: sql)
        }
        self.db = db
        self.stmt = s
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    /// Binds `params` to `?1`, `?2`, … in order, runs the statement to completion, and returns all rows.
    @discardableResult
    func run(_ params: [SQLValue] = []) throws -> [[SQLValue]] {
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32 = switch param {
            case .null: sqlite3_bind_null(stmt, index)
            case .int(let v): sqlite3_bind_int64(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError(code: rc, message: db.errorMessage, sql: sql)
            }
        }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE {
                return rows
            }
            guard rc == SQLITE_ROW else {
                throw SQLiteError(code: rc, message: db.errorMessage, sql: sql)
            }
            let columnCount = sqlite3_column_count(stmt)
            rows.append((0..<columnCount).map { col in
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_NULL: .null
                case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, col))
                default: .text(String(cString: sqlite3_column_text(stmt, col)))
                }
            })
        }
    }
}
