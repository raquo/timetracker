/// The user's choice, `app_page_reading_choice.page_reading_choice`.
enum PageReadingChoice: Int64 {
    /// Follow the probe result.
    case auto = 0
    case on = 1
    case off = 2
}

/// One app's row in the server's `app_page_reading_choice`.
struct AppPageReadingChoice {
    let choice: PageReadingChoice
    let reprobeRequestedAtMs: Int64?
}

/// One app's `tracker_app_page_probe` row.
struct AppPageProbes {
    /// nil: not decided yet.
    var hasContentPages: Bool? = nil
    var decidedAtMs: Int64? = nil
    var probeCount: Int64 = 0
    var firstProbeAtMs: Int64 = 0
    var lastProbeAtMs: Int64 = 0
}

/// Database access for `PageReadingPolicy`:
/// - the probe results, `tracker_app_page_probe`, which the tracker owns;
/// - the user's choices, the server's `app_page_reading_choice` (written from the UI), which
///   the tracker only reads. It may not exist yet.
final class PageReadingStore {
    static let choiceTable = "app_page_reading_choice"

    private let db: Database
    private let readDataVersion: Statement
    private let upsertProbes: Statement
    private var dataVersion: Int64?

    init(db: Database) throws {
        self.db = db
        readDataVersion = try db.prepare("PRAGMA data_version")
        upsertProbes = try db.prepare("""
            INSERT INTO tracker_app_page_probe (
                identifier_type, identifier, has_content_pages, decided_at_ms,
                probe_count, first_probe_at_ms, last_probe_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (identifier_type, identifier) DO UPDATE SET
                has_content_pages = excluded.has_content_pages,
                decided_at_ms = excluded.decided_at_ms,
                probe_count = excluded.probe_count,
                first_probe_at_ms = excluded.first_probe_at_ms,
                last_probe_at_ms = excluded.last_probe_at_ms
            """)
    }

    func loadProbes() throws -> [AppIdentity: AppPageProbes] {
        let rows = try db.query("""
            SELECT identifier_type, identifier, has_content_pages, decided_at_ms,
                probe_count, first_probe_at_ms, last_probe_at_ms
            FROM tracker_app_page_probe
            """)
        var result: [AppIdentity: AppPageProbes] = [:]
        for row in rows {
            guard let app = Self.app(row[0], row[1]), let probeCount = row[4].int, let firstProbeAtMs = row[5].int, let lastProbeAtMs = row[6].int else {
                continue
            }
            result[app] = AppPageProbes(
                hasContentPages: row[2].int.map { $0 != 0 },
                decidedAtMs: row[3].int,
                probeCount: probeCount,
                firstProbeAtMs: firstProbeAtMs,
                lastProbeAtMs: lastProbeAtMs
            )
        }
        return result
    }

    func save(_ probes: AppPageProbes, for app: AppIdentity) throws {
        try upsertProbes.run([
            .int(app.type.rawValue), .text(app.identifier),
            SQLValue(probes.hasContentPages), SQLValue(probes.decidedAtMs),
            .int(probes.probeCount), .int(probes.firstProbeAtMs), .int(probes.lastProbeAtMs),
        ])
    }

    /// The user's choices if another connection wrote to the database since the last call
    /// (`PRAGMA data_version`), else nil. Cheap enough to call on every sample.
    func choicesIfChanged() throws -> [AppIdentity: AppPageReadingChoice]? {
        let version = try readDataVersion.value()?.int
        guard version != dataVersion else {
            return nil
        }
        // Set first: a broken table is then reported once per change, not on every call.
        dataVersion = version
        return try loadChoices()
    }

    /// The server's table, or nothing if it doesn't exist (yet). Rows with unknown values are skipped.
    private func loadChoices() throws -> [AppIdentity: AppPageReadingChoice] {
        let tables = try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(Self.choiceTable)])
        guard !tables.isEmpty else {
            return [:]
        }
        let rows = try db.query("""
            SELECT identifier_type, identifier, page_reading_choice, reprobe_requested_at_ms FROM \(Self.choiceTable)
            """)
        var result: [AppIdentity: AppPageReadingChoice] = [:]
        for row in rows {
            guard let app = Self.app(row[0], row[1]), let choice = row[2].int.flatMap(PageReadingChoice.init(rawValue:)) else {
                log.warning("Skipping invalid row in \(Self.choiceTable, privacy: .public)")
                continue
            }
            result[app] = AppPageReadingChoice(choice: choice, reprobeRequestedAtMs: row[3].int)
        }
        log.info("Loaded \(result.count) page reading choices")
        return result
    }

    private static func app(_ type: SQLValue, _ identifier: SQLValue) -> AppIdentity? {
        guard let type = type.int.flatMap(AppIdentifierType.init(rawValue:)), let identifier = identifier.text else {
            return nil
        }
        return AppIdentity(type: type, identifier: identifier)
    }
}
