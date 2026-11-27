import Foundation
import Testing
@testable import TrackerCore

/// A database in a fresh temporary folder, deleted when this is released. Migrated unless
/// `isMigrated` is false.
final class TempDatabase {
    let folder: URL
    let path: String
    let db: Database

    init(isMigrated: Bool = true) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = folder.appendingPathComponent("test.db").path
        db = try Database(path: path)
        if isMigrated {
            try Schema.migrate(db)
        }
    }

    /// Makes every `operation` (INSERT, UPDATE or DELETE) on `tracker_interval` fail, until
    /// `restoreWrites`. A TEMP trigger: only this connection, never saved to the file.
    func failWrites(_ operation: String) throws {
        try db.exec("CREATE TEMP TRIGGER injected_failure BEFORE \(operation) ON main.tracker_interval BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
    }

    func restoreWrites() throws {
        try db.exec("DROP TRIGGER temp.injected_failure")
    }

    /// Rows changed by this connection so far (SQLite's `total_changes()`).
    func totalChanges() throws -> Int64 {
        try db.query("SELECT total_changes()").first![0].int!
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A second connection to the same file, like the server's.
    func otherConnection() throws -> Database {
        try Database(path: path)
    }

    /// All `tracker_interval` rows, by start time, with lookups resolved.
    func intervals(sourceLocation: SourceLocation = #_sourceLocation) throws -> [StoredInterval] {
        try db.query("""
            SELECT i.start_ms, i.end_ms,
                a.identifier_type, a.identifier, a.app_path, a.name,
                t.title, p.path, u.url, pt.title, r.role, r.subrole,
                i.is_input_idle, i.is_screen_locked, i.is_main_window, i.is_full_screen,
                i.display_sleep_holders, i.is_camera_in_use, i.mic_holders
            FROM tracker_interval i
            LEFT JOIN tracker_app a ON a.id = i.app_id
            LEFT JOIN tracker_title t ON t.id = i.title_id
            LEFT JOIN tracker_path p ON p.id = i.document_path_id
            LEFT JOIN tracker_url u ON u.id = i.page_url_id
            LEFT JOIN tracker_title pt ON pt.id = i.page_title_id
            LEFT JOIN tracker_window_role r ON r.id = i.window_role_id
            ORDER BY i.start_ms, i.id
            """).map { (r: [SqlValue]) -> StoredInterval in
            StoredInterval(
                startMs: r[0].int!,
                endMs: r[1].int!,
                app: r[2].int.map { StoredApp(type: AppIdentifierType(rawValue: $0)!, identifier: r[3].text!, path: r[4].text!, name: r[5].text!) },
                windowTitle: r[6].text,
                documentPath: r[7].text,
                pageUrl: r[8].text,
                pageTitle: r[9].text,
                windowRole: r[10].text,
                windowSubrole: r[11].text,
                isInputIdle: r[12].int! != 0,
                isScreenLocked: r[13].int! != 0,
                isMainWindow: r[14].int.map { $0 != 0 },
                isFullScreen: r[15].int.map { $0 != 0 },
                displaySleepHolders: r[16].text,
                isCameraInUse: r[17].int.map { $0 != 0 },
                micHolders: r[18].text
            )
        }
    }

    /// Number of rows in `table`.
    func count(_ table: String) throws -> Int64 {
        try db.query("SELECT count(*) FROM \(table)").first![0].int!
    }
}

struct StoredApp: Equatable {
    let type: AppIdentifierType
    let identifier: String
    let path: String
    let name: String
}

/// One `tracker_interval` row as the database holds it.
struct StoredInterval: Equatable, CustomStringConvertible {
    var startMs: Int64
    var endMs: Int64
    var app: StoredApp?
    var windowTitle: String?
    var documentPath: String?
    var pageUrl: String?
    var pageTitle: String?
    var windowRole: String?
    var windowSubrole: String?
    var isInputIdle: Bool
    var isScreenLocked: Bool
    var isMainWindow: Bool?
    var isFullScreen: Bool?
    /// Raw JSON.
    var displaySleepHolders: String?
    var isCameraInUse: Bool?
    var micHolders: String?

    /// The row the tracker should store for `s` from `startMs` to `endMs`. Test snapshots
    /// always carry a name and a bundle path, so the app's columns are spelled out here
    /// rather than derived with the code under test.
    init(_ s: Snapshot, _ startMs: Int64, _ endMs: Int64) {
        self.startMs = startMs
        self.endMs = endMs
        if let bundleId = s.bundleId {
            app = StoredApp(type: .bundleId, identifier: bundleId, path: s.bundlePath!, name: s.appName!)
        }
        windowTitle = s.windowTitle
        documentPath = s.documentPath
        pageUrl = s.pageUrl
        pageTitle = s.pageTitle
        // '' stands for an unknown half of a known pair.
        if s.windowRole != nil || s.windowSubrole != nil {
            windowRole = s.windowRole ?? ""
            windowSubrole = s.windowSubrole ?? ""
        }
        isInputIdle = s.isInputIdle
        isScreenLocked = s.isScreenLocked
        isMainWindow = s.isMainWindow
        isFullScreen = s.isFullScreen
        isCameraInUse = s.presence.isCameraInUse
        // Holder JSON holds row IDs: tests with holders spell it out.
        precondition((s.presence.displaySleepHolders?.isEmpty ?? true) && (s.presence.micHolders?.isEmpty ?? true),"spell out rows with holders")
        displaySleepHolders = s.presence.displaySleepHolders.map { _ in "[]" }
        micHolders = s.presence.micHolders.map { _ in "[]" }
    }

    init(
        startMs: Int64, endMs: Int64, app: StoredApp?, windowTitle: String?, documentPath: String?,
        pageUrl: String?, pageTitle: String?, windowRole: String?, windowSubrole: String?,
        isInputIdle: Bool, isScreenLocked: Bool, isMainWindow: Bool?, isFullScreen: Bool?,
        displaySleepHolders: String? = nil, isCameraInUse: Bool? = nil, micHolders: String? = nil
    ) {
        self.startMs = startMs
        self.endMs = endMs
        self.app = app
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.pageUrl = pageUrl
        self.pageTitle = pageTitle
        self.windowRole = windowRole
        self.windowSubrole = windowSubrole
        self.isInputIdle = isInputIdle
        self.isScreenLocked = isScreenLocked
        self.isMainWindow = isMainWindow
        self.isFullScreen = isFullScreen
        self.displaySleepHolders = displaySleepHolders
        self.isCameraInUse = isCameraInUse
        self.micHolders = micHolders
    }

    var description: String {
        "[\(startMs)–\(endMs)) \(app?.identifier ?? "-") \"\(windowTitle ?? "-")\" \(pageUrl ?? "-") \"\(pageTitle ?? "-")\""
            + (isInputIdle ? " idle" : "") + (isScreenLocked ? " locked" : "")
    }
}
