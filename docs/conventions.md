# Conventions

Rules for code and data across all pieces.

## Timestamps and durations

**All timestamps are Unix epoch milliseconds, always whole numbers:** never seconds, and never in a 32-bit integer. Durations likewise.

- **SQLite:** `INTEGER`.
- **Swift:** `Int64`. Get the time from the shared `nowMs()`. Convert from `Double` only after checking `isFinite`, because `Int64(Double)` traps on infinity and NaN.
- **Names** end in `_ms` in SQL and `Ms` in code (`start_ms`, `atMs`), so the unit is never in doubt.

### Scala (TBD: to confirm when the server and UI are started)

Proposed: `Double`-backed types in the shared model, `Long` only at the JVM's edges.

- **Shared module (JVM + JS):** opaque types `EpochMs` and `DurationMs` over `Double`. Arithmetic is defined only where it makes sense: timestamp − timestamp = duration, timestamp ± duration = timestamp, no timestamp + timestamp. Constructors reject NaN and infinity and round to whole milliseconds, so division, averaging or pixel ↔ time conversions can't leave fractions in them.
- **JVM edges:** `Long` from JDBC (`getLong`), `java.time.Instant` via `ofEpochMilli`. Converted in the database layer, not spread through server code.
- **Scala.js:** no conversion needed for `js.Date`, `Date.now()` and JS libraries, which all take `Double`.
- **JSON (borer):** written as an integer (`writeLong`), read back into a `Double`. The wire format matches the database and never contains `1.7E12`. Test a round trip of a post-2038 value (e.g. `4102444800000`, 2100-01-01) on both JVM and JS.
- **Printing:** format explicitly. `Double.toString` uses scientific notation for timestamps.

To confirm: that opaque types work for us (they need Scala 3; Scala 2 `AnyVal` wrappers get boxed in Scala.js collections), and how the rounding constructors feel in real timeline code.

The rejected alternative was `Long` everywhere in Scala. It works on both platforms, but in Scala.js it's emulated (slower, boxed) and needs a `.toDouble` at every JS API, deep in rendering code. With a shared model, one platform has to convert at its edges either way, and the JVM's edges are fewer.

**Why whole milliseconds:** one unit everywhere means no conversions to get wrong between the pieces. A `Double` holds every whole millisecond exactly up to 2^53, about 285,000 years, and sums and differences of whole numbers stay exact. 64-bit integers avoid the 2038 rollover, which is a signed 32-bit seconds problem.

## Naming

- **Acronyms and initialisms are words** when camel-casing, in every language: only their first letter is capitalized, like any other word. `pageUrl`, `bundleId`, `rowId`, `AxElement`, `SqlValue`, `UrlScrubber`, not `pageURL`, `bundleID`, `AXElement`, `SQLValue`. So word boundaries stay visible (`AxUiElementId`, not `AXUIElementID`) and there's one way to spell each name. Exceptions: names we don't own (Apple's `AXUIElement`, `kAXTitleAttribute`, `URL`, `NSWorkspace`) stay as they are, and so do string values from outside (the `AXRole` attribute name, `"AXStandardWindow"`). In `snake_case` and `SCREAMING_CASE` they're lowercase or uppercase like other words (`page_url_id`, `TIMETRACKER_DB`).
- **Booleans are named as such:** `is_` / `has_` in SQL, `isX` / `hasX` in code. SQLite stores them as `INTEGER` 0 / 1.
- **No generic column names** like `value`, `mode` or `enabled`: say what the value is and, where two sides could hold one, who decided it (a user's *choice* vs a tracker's *probe result*).
- **Enumerations in SQLite are small integers** with their meaning in a schema comment and a matching Swift `enum` (e.g. `identifier_type`: 0 = bundle ID, 1 = executable path; `AppIdentifierType`).

## Database migrations

- **Each side owns its migrations,** applied in order on startup, with a version in its own table (`tracker_schema` for the tracker), not `PRAGMA user_version`, which the two sides would share.
- **A migration that has run on real data is never edited; append a new one.**
- **The exception is a data reset,** only before the app has users other than its developer: a migration may then be edited in place together with deleting the database.
- **The tracker refuses a database newer than itself** (a schema version above its migration count), rather than writing to tables it doesn't know.
- **Changing a `CHECK` constraint or a column's type** means rebuilding the table (create a new table, copy, drop, rename), since SQLite can't alter them.

## Scala style

Put `if` / `else` conditions and branches on separate lines; same for `try` / `catch` and `for` / `yield`. The Swift code follows the same layout.
