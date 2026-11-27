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

        // 4: what probing found out about each app: whether it shows content pages, so whether
        // reading them is worth it. No row: not decided yet. The user's choice, which overrides
        // this, lives in the server's `app_page_reading_choice`. See `PageReadingPolicy`.
        """
        CREATE TABLE tracker_app_page_probe (
            -- The app, as in tracker_app minus app_path: 0 = bundle ID, 1 = executable path.
            identifier_type   INTEGER NOT NULL CHECK (identifier_type IN (0, 1)),
            identifier        TEXT NOT NULL,
            -- 1: a probe saw a content page. 0: none seen in 30 min of active use.
            has_content_pages INTEGER NOT NULL,
            -- When this result was decided. A re-probe requested after it starts probing again.
            probed_at_ms      INTEGER NOT NULL,
            PRIMARY KEY (identifier_type, identifier)
        );
        """,

        // 5: a row from the first probe on, not just once decided, with probe counts, to show
        // whether and how much an app has been probed. probed_at_ms becomes decided_at_ms.
        // Rows from 4 were all decided by one probe (count 1 is a guess for any decided off).
        """
        CREATE TABLE tracker_app_page_probe_new (
            identifier_type   INTEGER NOT NULL CHECK (identifier_type IN (0, 1)),
            identifier        TEXT NOT NULL,
            -- 1: a probe saw a content page. 0: none seen in 30 min of active use. NULL: not decided yet.
            has_content_pages INTEGER,
            -- When has_content_pages was decided. A re-probe requested after it starts probing again.
            decided_at_ms     INTEGER,
            -- Probes so far, and when the first and last ran. Saved on the first probe, on a
            -- decision, and when the tracker quits or the Mac sleeps, not on every probe.
            probe_count       INTEGER NOT NULL,
            first_probe_at_ms INTEGER NOT NULL,
            last_probe_at_ms  INTEGER NOT NULL,
            PRIMARY KEY (identifier_type, identifier),
            CHECK ((has_content_pages IS NULL) = (decided_at_ms IS NULL))
        );
        INSERT INTO tracker_app_page_probe_new
            SELECT identifier_type, identifier, has_content_pages, probed_at_ms, 1, probed_at_ms, probed_at_ms
            FROM tracker_app_page_probe;
        DROP TABLE tracker_app_page_probe;
        ALTER TABLE tracker_app_page_probe_new RENAME TO tracker_app_page_probe;
        """,

        // 6: clearer names. path_id holds the focused window's document (AXDocument); url_id is
        // the URL of the same page as page_title_id; is_idle means "no user input", not an idle CPU or app.
        // Also: is_full_screen is recorded (NULL when not reported), despite the comment in 1; and
        // page_title_id / page_url_id are read in apps where page reading is on, not an allowlist (see 3).
        """
        ALTER TABLE tracker_interval RENAME COLUMN path_id TO document_path_id;
        ALTER TABLE tracker_interval RENAME COLUMN url_id TO page_url_id;
        ALTER TABLE tracker_interval RENAME COLUMN is_idle TO is_input_idle;
        """,

        // 7: presence signals. is_camera_in_use (from 1) is recorded from here on. The holder
        // lists replace has_display_sleep_assertion and is_mic_in_use (from 1, always NULL), which
        // would only repeat whether a list is empty. JSON arrays of {"app": tracker_app.id,
        // "rsn": assertion name, "via": tracker_app.id of a proxy}, keys left out when unknown,
        // in canonical order (Swift: `HolderEntry`). '[]': none; NULL: not measured (screen
        // locked, read failed).
        """
        ALTER TABLE tracker_interval ADD COLUMN display_sleep_holders TEXT;
        ALTER TABLE tracker_interval ADD COLUMN mic_holders TEXT;
        ALTER TABLE tracker_interval DROP COLUMN has_display_sleep_assertion;
        ALTER TABLE tracker_interval DROP COLUMN is_mic_in_use;
        """,
    ]

    static func migrate(_ db: Database) throws {
        try db.transaction {
            try db.exec("CREATE TABLE IF NOT EXISTS tracker_schema (version INTEGER NOT NULL)")
            var version: Int64
            if let current = try db.prepare("SELECT version FROM tracker_schema").value()?.int {
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
            try db.query("UPDATE tracker_schema SET version = ?", [.int(version)])
        }
    }
}
