import Foundation
import Testing
@testable import TrackerCore

/// A page reading policy on a temporary database, driven with times relative to `t0`, plus a
/// second connection standing in for the server.
final class PolicyHarness {
    let temp: TempDatabase
    private(set) var policy: PageReadingPolicy
    private lazy var server: Database = try! temp.otherConnection()

    init() throws {
        temp = try TempDatabase()
        policy = try PageReadingPolicy(store: PageReadingStore(db: temp.db))
    }

    /// A new policy on the same database, as after a restart.
    func restart() throws {
        policy = try PageReadingPolicy(store: PageReadingStore(db: temp.db))
    }

    /// One sample, as `Sampler` takes it: probes the window when probing and due, then notes
    /// the sample. Returns the mode the sample ran with.
    @discardableResult
    func tick(_ app: AppIdentity, at: Int64, window: String = "w1", pid: pid_t = 100, isActive: Bool = true, hasWindow: Bool = true, hasContentPages: Bool = false) -> PageReadingMode {
        policy.refresh()
        let mode = policy.mode(for: app)
        if hasWindow, mode == .probing, policy.isProbeDue(app: app, pid: pid, window: window, atMs: t0 + at) {
            policy.noteProbe(app: app, pid: pid, window: window, hasContentPages: hasContentPages, atMs: t0 + at)
        }
        policy.noteSample(app: app, mode: mode, isActive: isActive, hasProbeableWindow: hasWindow, atMs: t0 + at)
        return mode
    }

    func probe(_ app: AppIdentity, at: Int64, window: String = "w1", pid: pid_t = 100, hasContentPages: Bool = false) {
        policy.noteProbe(app: app, pid: pid, window: window, hasContentPages: hasContentPages, atMs: t0 + at)
    }

    func sample(_ app: AppIdentity?, at: Int64, mode: PageReadingMode = .probing, isActive: Bool = true, hasWindow: Bool = true) {
        policy.noteSample(app: app, mode: mode, isActive: isActive, hasProbeableWindow: hasWindow, atMs: t0 + at)
    }

    /// `tracker_app_page_probe` rows: identifier, has_content_pages, decided_at_ms, probe_count,
    /// first_probe_at_ms, last_probe_at_ms; times relative to `t0`.
    func probeRows() throws -> [ProbeRow] {
        try temp.db.query("""
            SELECT identifier_type, identifier, has_content_pages, decided_at_ms, probe_count, first_probe_at_ms, last_probe_at_ms
            FROM tracker_app_page_probe ORDER BY identifier
            """).map { r in
            ProbeRow(
                app: AppIdentity(type: AppIdentifierType(rawValue: r[0].int!)!, identifier: r[1].text!),
                hasContentPages: r[2].int.map { $0 != 0 },
                decidedAt: r[3].int.map { $0 - t0 },
                count: r[4].int!,
                firstAt: r[5].int! - t0,
                lastAt: r[6].int! - t0
            )
        }
    }

    /// Creates the server's table (if needed) and writes `app`'s choice, from the other connection.
    func setChoice(_ app: AppIdentity, _ choice: Int64, reprobeAt: Int64? = nil) throws {
        try createChoiceTable()
        try server.query(
            "INSERT OR REPLACE INTO app_page_reading_choice VALUES (?, ?, ?, ?)",
            [.int(app.type.rawValue), .text(app.identifier), .int(choice), SqlValue(reprobeAt.map { t0 + $0 })]
        )
    }

    func serverQuery(_ sql: String) throws {
        try server.query(sql)
    }

    func createChoiceTable() throws {
        // As in tracker/README.md.
        try server.exec("""
            CREATE TABLE IF NOT EXISTS app_page_reading_choice (
                identifier_type         INTEGER NOT NULL,
                identifier              TEXT NOT NULL,
                page_reading_choice     INTEGER NOT NULL,
                reprobe_requested_at_ms INTEGER,
                PRIMARY KEY (identifier_type, identifier)
            )
            """)
    }
}

struct ProbeRow: Equatable {
    let app: AppIdentity
    let hasContentPages: Bool?
    let decidedAt: Int64?
    let count: Int64
    let firstAt: Int64
    let lastAt: Int64
}
