import Testing
@testable import TrackerCore

struct SchemaTests {
    private func version(_ db: Database) throws -> Int64? {
        try db.query("SELECT version FROM tracker_schema").first?[0].int
    }

    private func tables(_ db: Database) throws -> [String] {
        try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { $0[0].text! }
    }

    @Test func freshDatabaseGetsEveryMigration() throws {
        let temp = try TempDatabase()
        #expect(Schema.migrations.count == 5)
        #expect(try version(temp.db) == 5)
        #expect(try temp.db.query("SELECT count(*) FROM tracker_schema") == [[.int(1)]])
        #expect(try tables(temp.db) == [
            "tracker_app", "tracker_app_page_probe", "tracker_interval", "tracker_path",
            "tracker_schema", "tracker_title", "tracker_url", "tracker_window_role",
        ])
    }

    @Test func migratingAgainChangesNothing() throws {
        let temp = try TempDatabase()
        let h = try RecorderHarness(temp: temp)
        try h.record(Fixtures.youtube, at: 0)
        try h.record(Fixtures.youtube, at: 5_000)
        try h.close()
        let before = try h.rows()
        try Schema.migrate(temp.db)
        #expect(try version(temp.db) == 5)
        #expect(try temp.db.query("SELECT count(*) FROM tracker_schema") == [[.int(1)]])
        #expect(try h.rows() == before)
    }

    @Test func newerDatabaseIsRefusedUntouched() throws {
        let temp = try TempDatabase()
        try temp.db.exec("UPDATE tracker_schema SET version = 6")
        let tablesBefore = try tables(temp.db)
        do {
            try Schema.migrate(temp.db)
            Issue.record("expected newerThanCode")
        }
        catch SchemaError.newerThanCode(let databaseVersion, let codeVersion) {
            #expect(databaseVersion == 6)
            #expect(codeVersion == 5)
        }
        #expect(try version(temp.db) == 6)
        #expect(try tables(temp.db) == tablesBefore)
    }

    @Test func version4ProbeResultsCarryOverTo5() throws {
        let temp = try TempDatabase(isMigrated: false)
        let db = temp.db
        try db.exec("CREATE TABLE tracker_schema (version INTEGER NOT NULL); INSERT INTO tracker_schema VALUES (4)")
        for migration in Schema.migrations[0..<4] {
            try db.exec(migration)
        }
        try db.exec("""
            INSERT INTO tracker_app_page_probe (identifier_type, identifier, has_content_pages, probed_at_ms) VALUES
                (0, 'notion.id', 1, 1000),
                (1, '/usr/local/bin/tool', 0, 2000)
            """)
        try Schema.migrate(db)
        #expect(try version(db) == 5)
        let rows = try db.query("""
            SELECT identifier_type, identifier, has_content_pages, decided_at_ms, probe_count, first_probe_at_ms, last_probe_at_ms
            FROM tracker_app_page_probe ORDER BY identifier_type
            """)
        #expect(rows == [
            [.int(0), .text("notion.id"), .int(1), .int(1000), .int(1), .int(1000), .int(1000)],
            [.int(1), .text("/usr/local/bin/tool"), .int(0), .int(2000), .int(1), .int(2000), .int(2000)],
        ])
        let policy = try PageReadingPolicy(store: PageReadingStore(db: db))
        #expect(policy.mode(for: AppIdentity(type: .bundleID, identifier: "notion.id")) == .on)
        #expect(policy.mode(for: AppIdentity(type: .executablePath, identifier: "/usr/local/bin/tool")) == .off)
        // The rebuilt table keeps its constraints.
        #expect(throws: SQLiteError.self) {
            try db.exec("INSERT INTO tracker_app_page_probe VALUES (0, 'x', 1, NULL, 1, 0, 0)")
        }
        #expect(throws: SQLiteError.self) {
            try db.exec("INSERT INTO tracker_app_page_probe VALUES (2, 'x', NULL, NULL, 1, 0, 0)")
        }
    }
}
