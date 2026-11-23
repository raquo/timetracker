import Foundation

/// Turns a stream of samples into `tracker_interval` rows.
///
/// The open interval lives in memory and its `end_ms` is flushed every `flushEveryMs`,
/// so a crash loses at most that much time and every row on disk is always valid.
///
/// Writes are separate autocommit statements, not one transaction: closing the previous row
/// must not depend on the lookups and insert for the next one succeeding. A failure between
/// them leaves a gap (the next sample opens a new row), never an overlap or a stale row.
final class Recorder {
    /// Samples further apart than this mean the tracker wasn't running (sleep, suspension, crash),
    /// so the interval ends at the last sample instead of stretching across the gap.
    static let maxGapMs: Int64 = 20_000  // 4 polls
    static let flushEveryMs: Int64 = 30_000

    private struct OpenInterval {
        let rowID: Int64
        let snapshot: Snapshot
        let startMs: Int64
        var endMs: Int64
        var flushedEndMs: Int64
    }

    private let db: Database
    private let apps: AppLookup
    private let titles: Lookup<String>
    private let paths: Lookup<String>
    private let urls: Lookup<String>
    private let windowRoles: Lookup<WindowRole>
    private let insertInterval: Statement
    private let updateEnd: Statement
    private let deleteInterval: Statement
    private var open: OpenInterval?

    /// Latest `end_ms` of any closed row. New rows never start before it, so rows never overlap,
    /// even when the wall clock jumps backwards (see "Record consistency" in notes/PLAN.md).
    private var watermarkMs: Int64
    private var isClockBehind = false

    init(db: Database) throws {
        self.db = db
        apps = try AppLookup(db: db)
        titles = try Lookup(db: db, table: "tracker_title", column: "title")
        paths = try Lookup(db: db, table: "tracker_path", column: "path")
        urls = try Lookup(db: db, table: "tracker_url", column: "url")
        windowRoles = try Lookup(db: db, table: "tracker_window_role", keyColumns: ["role", "subrole"]) { key in
            [.text(key.role), .text(key.subrole)]
        }
        insertInterval = try db.prepare("""
            INSERT INTO tracker_interval (
                start_ms, end_ms, app_id, title_id, path_id, url_id, page_title_id, window_role_id,
                is_idle, is_screen_locked, is_main_window, is_full_screen
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        updateEnd = try db.prepare("UPDATE tracker_interval SET end_ms = ? WHERE id = ?")
        deleteInterval = try db.prepare("DELETE FROM tracker_interval WHERE id = ?")
        watermarkMs = try db.prepare("SELECT MAX(end_ms) FROM tracker_interval").run().first?.first?.int ?? 0
    }

    /// The open row's snapshot, nil when there is none.
    var openSnapshot: Snapshot? {
        open?.snapshot
    }

    /// `changedAtMs`: when the change to this sample was first seen (see `Settler`); a new row
    /// starts there. At most `nowMs`.
    func record(_ sample: Sample, atMs nowMs: Int64, changedAtMs: Int64) throws {
        let snapshot = sample.snapshot
        if var current = open {
            // The open row was last seen at `endMs`; the next sample is now, or for a change, when it was first seen.
            let nextSeenMs = current.snapshot == snapshot ? nowMs : changedAtMs
            if nowMs < current.endMs || nextSeenMs - current.endMs > Self.maxGapMs {
                // Clock went backwards, or we missed samples: don't bridge the gap.
                try close()
            }
            else if current.snapshot == snapshot {
                current.endMs = nowMs
                // Kept in memory before flushing: a failed flush must not look like a gap next time.
                open = current
                if nowMs - current.flushedEndMs >= Self.flushEveryMs {
                    try updateEnd.run([.int(nowMs), .int(current.rowID)])
                    open?.flushedEndMs = nowMs
                }
                return
            }
            else {
                // The old state held at least until its last sample.
                var boundaryMs = min(nowMs, max(current.endMs, changedAtMs))
                // Going idle: the idle stretch really started at the last input, so backdate the boundary.
                if snapshot.isIdle, !current.snapshot.isIdle, let idleSinceMs = sample.idleSinceMs {
                    boundaryMs = min(boundaryMs, max(current.startMs, idleSinceMs))
                }
                // Close first, on its own. If this throws, `open` is kept and the next sample retries.
                if boundaryMs <= current.startMs {
                    try deleteInterval.run([.int(current.rowID)])
                }
                else {
                    try updateEnd.run([.int(boundaryMs), .int(current.rowID)])
                }
                watermarkMs = max(watermarkMs, boundaryMs)
                open = nil
                open = try insert(snapshot, startMs: boundaryMs, endMs: nowMs)
                return
            }
        }
        guard nowMs >= watermarkMs else {
            // The clock is behind time we've already recorded. Record nothing until it catches up.
            if !isClockBehind {
                isClockBehind = true
                log.warning("Clock is \(self.watermarkMs - nowMs) ms behind recorded data; pausing until it catches up")
            }
            return
        }
        if isClockBehind {
            isClockBehind = false
            log.info("Clock caught up with recorded data; recording again")
        }
        let startMs = min(nowMs, max(watermarkMs, changedAtMs))
        open = try insert(snapshot, startMs: startMs, endMs: nowMs)
    }

    /// Ends the open interval at the last sample. Call on sleep and on quit.
    /// If the write fails, the interval stays open and the next call retries.
    func close() throws {
        guard let current = open else {
            return
        }
        if current.endMs == current.startMs {
            // Opened by the last sample before closing: no duration, so no row.
            try deleteInterval.run([.int(current.rowID)])
        }
        else if current.endMs != current.flushedEndMs {
            try updateEnd.run([.int(current.endMs), .int(current.rowID)])
        }
        watermarkMs = max(watermarkMs, current.endMs)
        open = nil
    }

    private func insert(_ s: Snapshot, startMs: Int64, endMs: Int64) throws -> OpenInterval {
        let appID = try apps.id(for: s)
        let titleID = try titles.id(for: s.windowTitle)
        let pathID = try paths.id(for: s.documentPath)
        let urlID = try urls.id(for: s.url)
        let pageTitleID = try titles.id(for: s.pageTitle)
        let windowRoleID = try windowRoles.id(for: WindowRole(role: s.windowRole, subrole: s.windowSubrole))
        try insertInterval.run([
            .int(startMs), .int(endMs),
            SQLValue(appID), SQLValue(titleID), SQLValue(pathID), SQLValue(urlID), SQLValue(pageTitleID), SQLValue(windowRoleID),
            SQLValue(s.isIdle), SQLValue(s.isScreenLocked), SQLValue(s.isMainWindow), SQLValue(s.isFullScreen),
        ])
        return OpenInterval(rowID: db.lastInsertRowID, snapshot: s, startMs: startMs, endMs: endMs, flushedEndMs: endMs)
    }
}
