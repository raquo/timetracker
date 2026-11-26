/// Reads and writes `tracker_interval` rows, resolving a snapshot's attributes to lookup table
/// IDs. Each call is its own autocommit statement (see `Recorder`).
final class IntervalStore {
    private let db: Database
    private let apps: AppLookup
    private let titles: Lookup<String>
    private let paths: Lookup<String>
    private let urls: Lookup<String>
    private let windowRoles: Lookup<WindowRole>
    private let insertRow: Statement
    private let updateEnd: Statement
    private let deleteRow: Statement
    private let selectLatestEnd: Statement

    init(db: Database) throws {
        self.db = db
        apps = try AppLookup(db: db)
        titles = try Lookup(db: db, table: "tracker_title", column: "title")
        paths = try Lookup(db: db, table: "tracker_path", column: "path")
        urls = try Lookup(db: db, table: "tracker_url", column: "url")
        windowRoles = try Lookup(db: db, table: "tracker_window_role", keyColumns: ["role", "subrole"]) { key in
            [.text(key.role), .text(key.subrole)]
        }
        insertRow = try db.prepare("""
            INSERT INTO tracker_interval (
                start_ms, end_ms, app_id, title_id, document_path_id, page_url_id, page_title_id, window_role_id,
                is_input_idle, is_screen_locked, is_main_window, is_full_screen
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        updateEnd = try db.prepare("UPDATE tracker_interval SET end_ms = ? WHERE id = ?")
        deleteRow = try db.prepare("DELETE FROM tracker_interval WHERE id = ?")
        selectLatestEnd = try db.prepare("SELECT MAX(end_ms) FROM tracker_interval")
    }

    /// The latest `end_ms` of any row, 0 when there are none.
    func latestEndMs() throws -> Int64 {
        try selectLatestEnd.value()?.int ?? 0
    }

    /// Returns the new row's ID.
    func insert(_ s: Snapshot, startMs: Int64, endMs: Int64) throws -> Int64 {
        let appId = try apps.id(for: s)
        let titleId = try titles.id(for: s.windowTitle)
        let documentPathId = try paths.id(for: s.documentPath)
        let pageUrlId = try urls.id(for: s.pageUrl)
        let pageTitleId = try titles.id(for: s.pageTitle)
        let windowRoleId = try windowRoles.id(for: WindowRole(role: s.windowRole, subrole: s.windowSubrole))
        try insertRow.run([
            .int(startMs), .int(endMs),
            SqlValue(appId), SqlValue(titleId), SqlValue(documentPathId), SqlValue(pageUrlId), SqlValue(pageTitleId), SqlValue(windowRoleId),
            SqlValue(s.isInputIdle), SqlValue(s.isScreenLocked), SqlValue(s.isMainWindow), SqlValue(s.isFullScreen),
        ])
        return db.lastInsertRowId
    }

    func setEnd(_ endMs: Int64, rowId: Int64) throws {
        try updateEnd.run([.int(endMs), .int(rowId)])
    }

    func delete(rowId: Int64) throws {
        try deleteRow.run([.int(rowId)])
    }
}
