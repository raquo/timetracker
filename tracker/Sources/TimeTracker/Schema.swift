import Foundation

/// The tracker's own tables. All are prefixed `tracker_`; the server never writes them.
///
/// The tracker keeps its schema version in `tracker_schema`, not `PRAGMA user_version`,
/// because the server shares the database file and migrates its own tables separately.
enum SchemaError: Error, CustomStringConvertible {
    case newerThanCode(databaseVersion: Int64, codeVersion: Int)

    var description: String {
        switch self {
        case .newerThanCode(let databaseVersion, let codeVersion):
            "Database schema version \(databaseVersion) is newer than this tracker (\(codeVersion))."
        }
    }
}

enum Schema {
    /// `migrations[i]` takes the schema from version `i` to `i + 1`.
    /// Never edit a migration once it has run on real data; append a new one.
    static let migrations: [String] = [
        // 1: initial schema
        """
        -- One row per app per install location: the same bundle ID at two paths is two rows,
        -- so history keeps which copy ran (and apps can be re-identified by path later).
        -- Group by (identifier_type, identifier) to get "the app".
        CREATE TABLE tracker_app (
            id              INTEGER PRIMARY KEY,
            -- What `identifier` is: 0 = bundle ID, 1 = executable path (processes without a bundle ID).
            -- Swift: `AppIdentifierType`.
            identifier_type INTEGER NOT NULL CHECK (identifier_type IN (0, 1)),
            identifier      TEXT NOT NULL,
            -- The .app bundle's path, or the executable's path when there is no bundle. '' if macOS didn't say.
            app_path        TEXT NOT NULL,
            -- Localized display name, as last seen. Updated in place when it changes.
            name            TEXT NOT NULL,
            UNIQUE (identifier_type, identifier, app_path)
        );
        CREATE TABLE tracker_title (id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE);
        CREATE TABLE tracker_path  (id INTEGER PRIMARY KEY, path  TEXT NOT NULL UNIQUE);
        CREATE TABLE tracker_url   (id INTEGER PRIMARY KEY, url   TEXT NOT NULL UNIQUE);

        -- One row per stretch of time with identical attributes.
        -- Gaps between rows mean the tracker was not running, or the Mac was asleep.
        CREATE TABLE tracker_interval (
            id       INTEGER PRIMARY KEY,
            start_ms INTEGER NOT NULL,  -- Unix epoch milliseconds, inclusive
            end_ms   INTEGER NOT NULL,  -- Unix epoch milliseconds, exclusive
            app_id   INTEGER REFERENCES tracker_app (id),
            title_id INTEGER REFERENCES tracker_title (id),
            path_id  INTEGER REFERENCES tracker_path (id),
            url_id   INTEGER REFERENCES tracker_url (id),
            -- 1 while inside a stretch of at least 60 s with no user input.
            -- The interval starts at the last input, not when the 60 s ran out.
            is_idle          INTEGER NOT NULL,
            -- 1 while the screen is locked. App and title are NULL then.
            is_screen_locked INTEGER NOT NULL,
            -- Signals not recorded yet. NULL means "not measured", unlike 0.
            has_display_sleep_assertion INTEGER,
            is_camera_in_use            INTEGER,
            is_mic_in_use               INTEGER,
            is_full_screen              INTEGER,
            CHECK (end_ms >= start_ms)
        );
        CREATE INDEX tracker_interval_start ON tracker_interval (start_ms);
        """,

        // 2: what kind of window was focused, so panels, popups and Picture-in-Picture windows
        // can be told apart from normal document / browser windows. NULL in older rows: not recorded.
        """
        CREATE TABLE tracker_window_role (
            id      INTEGER PRIMARY KEY,
            role    TEXT NOT NULL,  -- AXRole of the focused window, usually 'AXWindow'; '' if not reported
            subrole TEXT NOT NULL,  -- AXSubrole: 'AXStandardWindow', 'AXDialog', 'AXFloatingWindow', ...; '' if not reported
            UNIQUE (role, subrole)
        );
        ALTER TABLE tracker_interval ADD COLUMN window_role_id INTEGER REFERENCES tracker_window_role (id);
        -- AXMain: 1 if the focused window is also the app's main window. A focused panel or popup usually isn't.
        ALTER TABLE tracker_interval ADD COLUMN is_main_window INTEGER;
        """,

        // 3: title of the page in the focused window's web content (allowlisted apps, read via
        // AXWebArea), e.g. the conversation name in Claude, whose window title is always "Claude".
        // Shares tracker_title with window titles. url_id holds the same page's URL.
        """
        ALTER TABLE tracker_interval ADD COLUMN page_title_id INTEGER REFERENCES tracker_title (id);
        """,
    ]

    static func migrate(_ db: Database) throws {
        try db.transaction {
            try db.exec("CREATE TABLE IF NOT EXISTS tracker_schema (version INTEGER NOT NULL)")
            var version: Int64
            if let current = try db.prepare("SELECT version FROM tracker_schema").run().first?.first?.int {
                version = current
            }
            else {
                try db.exec("INSERT INTO tracker_schema (version) VALUES (0)")
                version = 0
            }
            guard version <= migrations.count else {
                throw SchemaError.newerThanCode(databaseVersion: version, codeVersion: migrations.count)
            }
            while version < migrations.count {
                try db.exec(migrations[Int(version)])
                version += 1
            }
            try db.prepare("UPDATE tracker_schema SET version = ?").run([.int(version)])
        }
    }
}
