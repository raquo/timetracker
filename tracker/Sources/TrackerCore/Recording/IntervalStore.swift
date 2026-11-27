import Foundation

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
                is_input_idle, is_screen_locked, is_main_window, is_full_screen,
                display_sleep_holders, is_camera_in_use, mic_holders
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        let appId = try apps.id(for: s.processApp)
        let titleId = try titles.id(for: s.windowTitle)
        let documentPathId = try paths.id(for: s.documentPath)
        let pageUrlId = try urls.id(for: s.pageUrl)
        let pageTitleId = try titles.id(for: s.pageTitle)
        let windowRoleId = try windowRoles.id(for: WindowRole(role: s.windowRole, subrole: s.windowSubrole))
        try insertRow.run([
            .int(startMs), .int(endMs),
            SqlValue(appId), SqlValue(titleId), SqlValue(documentPathId), SqlValue(pageUrlId), SqlValue(pageTitleId), SqlValue(windowRoleId),
            SqlValue(s.isInputIdle), SqlValue(s.isScreenLocked), SqlValue(s.isMainWindow), SqlValue(s.isFullScreen),
            SqlValue(try holdersJson(s.presence.displaySleepHolders)), SqlValue(s.presence.isCameraInUse),
            SqlValue(try holdersJson(s.presence.micHolders)),
        ])
        return db.lastInsertRowId
    }

    func setEnd(_ endMs: Int64, rowId: Int64) throws {
        try updateEnd.run([.int(endMs), .int(rowId)])
    }

    func delete(rowId: Int64) throws {
        try deleteRow.run([.int(rowId)])
    }

    /// `display_sleep_holders` / `mic_holders`: JSON, see `HolderEntry`. nil: not measured.
    private func holdersJson(_ holders: Set<SignalHolder>?) throws -> String? {
        guard let holders else {
            return nil
        }
        let entries = try holders.map { h in
            HolderEntry(app: try apps.id(for: h.app), rsn: h.reason, via: try apps.id(for: h.via))
        }
        return HolderEntry.json(entries)
    }
}

/// One holder in `display_sleep_holders` / `mic_holders`: `{"app":12,"rsn":"Video Wake Lock","via":31}`.
/// `app` and `via` are `tracker_app` IDs. A key is left out when its value is nil.
struct HolderEntry: Encodable {
    let app: Int64?
    let rsn: String?
    let via: Int64?

    /// A JSON array in canonical form, so equal sets give equal strings: sorted by `app`, `rsn`,
    /// `via` (absent first, names byte for byte), no duplicates, keys in that order.
    static func json(_ entries: [HolderEntry]) -> String {
        let sorted = entries.sorted { a, b in
            if a.app != b.app {
                return (a.app ?? -1) < (b.app ?? -1)
            }
            else if !isSameBytes(a.rsn, b.rsn) {
                guard let aRsn = a.rsn else {
                    return true
                }
                guard let bRsn = b.rsn else {
                    return false
                }
                return aRsn.utf8.lexicographicallyPrecedes(bRsn.utf8)
            }
            else {
                return (a.via ?? -1) < (b.via ?? -1)
            }
        }
        var unique: [HolderEntry] = []
        for entry in sorted {
            if let last = unique.last, last.app == entry.app, last.via == entry.via, isSameBytes(last.rsn, entry.rsn) {
                continue
            }
            unique.append(entry)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding Int64s and Strings can't fail.
        return String(decoding: try! encoder.encode(unique), as: UTF8.self)
    }

    private static func isSameBytes(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            true
        case (let a?, let b?):
            a.utf8.elementsEqual(b.utf8)
        default:
            false
        }
    }
}
