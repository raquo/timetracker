import ApplicationServices
import Foundation

/// What the tracker does with the pages shown in an app's windows.
enum PageReadingMode {
    /// Read the focused window's page on every sample, and watch it for changes.
    case on
    case off
    /// Not decided yet: search the focused window now and then (`isProbeDue`), without
    /// observers, and record no page meanwhile.
    case probing
}

/// The user's choice, `app_page_reading_choice.page_reading_choice`.
enum PageReadingChoice: Int64 {
    /// Follow the probe result.
    case auto = 0
    case on = 1
    case off = 2
}

/// Decides per app whether to read its pages, and finds out by probing for apps nobody has
/// decided on. See "Adaptive page reading" in notes/PLAN.md.
///
/// - The user's choice: the server's `app_page_reading_choice` (written from the UI), which the
///   tracker only reads. It may not exist; the tracker re-reads it when another connection has
///   written to the database (`PRAGMA data_version`).
/// - The probe result: `tracker_app_page_probe`, written here. On: a probe saw a content page.
///   Off: no probe saw one during `evidenceMs` of active use, counted within this run. Also
///   counts the probes, saved only now and then (`save`), not on every probe.
///
/// Confined to the tracker's queue.
final class PageReadingPolicy {
    /// Active use without a content page after which the probe result is off.
    static let evidenceMs: Int64 = 30 * 60 * 1000
    /// Each step between samples adds at most this much, so sleep, hangs and clock jumps add ~nothing.
    static let maxStepMs: Int64 = 10_000
    /// Probe the same window again after this long. A different window is probed right away.
    static let probeEveryMs: Int64 = 60_000

    static let choiceTable = "app_page_reading_choice"

    /// One app's `tracker_app_page_probe` row.
    private struct AppProbes {
        /// nil: not decided yet.
        var hasContentPages: Bool? = nil
        var decidedAtMs: Int64? = nil
        var probeCount: Int64 = 0
        var firstProbeAtMs: Int64 = 0
        var lastProbeAtMs: Int64 = 0
        /// Changed since last saved.
        var isUnsaved = false
    }

    private struct Choice {
        let choice: PageReadingChoice
        let reprobeRequestedAtMs: Int64?
    }

    private struct LastSample {
        let app: AppIdentity
        let atMs: Int64
        /// Active, and the app was being probed.
        let isCounted: Bool
    }

    private struct LastProbe {
        let pid: pid_t
        let window: AXUIElement
        let atMs: Int64
    }

    private let db: Database
    private let readDataVersion: Statement
    private let upsertProbes: Statement
    private var probes: [AppIdentity: AppProbes] = [:]
    private var choices: [AppIdentity: Choice] = [:]
    private var dataVersion: Int64?

    // Evidence for the off verdict, this run only.
    /// Active time while probing, per app.
    private var activeMs: [AppIdentity: Int64] = [:]
    /// Apps probed at least once since probing started, so their active time counts as evidence.
    private var probedApps: Set<AppIdentity> = []
    private var lastSample: LastSample?
    private var lastProbe: LastProbe?

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
        let rows = try db.prepare("""
            SELECT identifier_type, identifier, has_content_pages, decided_at_ms,
                probe_count, first_probe_at_ms, last_probe_at_ms
            FROM tracker_app_page_probe
            """).run()
        for row in rows {
            guard let app = Self.app(row[0], row[1]), let probeCount = row[4].int, let firstProbeAtMs = row[5].int, let lastProbeAtMs = row[6].int else {
                continue
            }
            probes[app] = AppProbes(
                hasContentPages: row[2].int.map { $0 != 0 },
                decidedAtMs: row[3].int,
                probeCount: probeCount,
                firstProbeAtMs: firstProbeAtMs,
                lastProbeAtMs: lastProbeAtMs
            )
        }
        refresh()
    }

    /// Re-reads the user's choices if another connection wrote to the database. Call once per sample.
    func refresh() {
        do {
            let version = try readDataVersion.run().first?.first?.int
            guard version != dataVersion else {
                return
            }
            // Set first: a broken table is then reported once per change, not on every sample.
            dataVersion = version
            choices = try loadChoices()
        }
        catch {
            log.error("Failed to read page reading choices: \(String(describing: error), privacy: .public)")
        }
    }

    /// The user's choice unless auto, else the probe result, else probing. A re-probe requested
    /// after the probe result makes it probing again.
    func mode(for app: AppIdentity) -> PageReadingMode {
        let choice = choices[app]
        switch choice?.choice ?? .auto {
        case .on:
            return .on
        case .off:
            return .off
        case .auto:
            break
        }
        guard let stats = probes[app], let hasContentPages = stats.hasContentPages, let decidedAtMs = stats.decidedAtMs else {
            return .probing
        }
        if let requestedAtMs = choice?.reprobeRequestedAtMs, requestedAtMs > decidedAtMs {
            return .probing
        }
        else if hasContentPages {
            return .on
        }
        else {
            return .off
        }
    }

    /// Whether to probe `window` now: it isn't the window probed last, or that was a while ago.
    func isProbeDue(pid: pid_t, window: AXUIElement, atMs nowMs: Int64) -> Bool {
        guard let last = lastProbe, last.pid == pid, CFEqual(last.window, window) else {
            return true
        }
        let sinceMs = nowMs - last.atMs
        return sinceMs >= Self.probeEveryMs || sinceMs < 0
    }

    /// A probe of `app`'s focused window found content pages, or not.
    func noteProbe(app: AppIdentity, pid: pid_t, window: AXUIElement, hasContentPages: Bool, atMs nowMs: Int64) {
        lastProbe = LastProbe(pid: pid, window: window, atMs: nowMs)
        var stats = probes[app] ?? AppProbes()
        let isFirstProbe = stats.probeCount == 0
        if isFirstProbe {
            stats.firstProbeAtMs = nowMs
        }
        stats.probeCount += 1
        stats.lastProbeAtMs = nowMs
        stats.isUnsaved = true
        probes[app] = stats
        if hasContentPages {
            decide(app, hasContentPages: true, atMs: nowMs)
        }
        else {
            probedApps.insert(app)
            if isFirstProbe {
                // So the database shows that probing has started.
                save(app)
            }
        }
    }

    /// Saves the probe counts not saved yet. Call before quitting or sleeping.
    func saveAll() {
        for (app, stats) in probes where stats.isUnsaved {
            save(app)
        }
    }

    /// Counts the time since the previous sample as active use of that sample's app, if it was
    /// active and being probed; decides off once that reaches `evidenceMs`. Call on every sample,
    /// after probing. `app`: the frontmost app, nil if none or the screen is locked.
    func noteSample(app: AppIdentity?, mode: PageReadingMode, isActive: Bool, atMs nowMs: Int64) {
        if let last = lastSample, last.isCounted, probedApps.contains(last.app) {
            let stepMs = min(max(nowMs - last.atMs, 0), Self.maxStepMs)
            let totalMs = activeMs[last.app, default: 0] + stepMs
            activeMs[last.app] = totalMs
            if totalMs >= Self.evidenceMs {
                decide(last.app, hasContentPages: false, atMs: nowMs)
            }
        }
        lastSample = app.map { LastSample(app: $0, atMs: nowMs, isCounted: isActive && mode == .probing) }
    }

    /// Only after at least one probe of `app` (`noteProbe`).
    private func decide(_ app: AppIdentity, hasContentPages: Bool, atMs nowMs: Int64) {
        probes[app]?.hasContentPages = hasContentPages
        probes[app]?.decidedAtMs = nowMs
        probes[app]?.isUnsaved = true
        activeMs[app] = nil
        probedApps.remove(app)
        log.info("Page reading probe result for \(app.identifier, privacy: .public): \(hasContentPages ? "has content pages" : "no content pages", privacy: .public)")
        save(app)
    }

    private func save(_ app: AppIdentity) {
        guard let stats = probes[app] else {
            return
        }
        do {
            try upsertProbes.run([
                .int(app.type.rawValue), .text(app.identifier),
                SQLValue(stats.hasContentPages), SQLValue(stats.decidedAtMs),
                .int(stats.probeCount), .int(stats.firstProbeAtMs), .int(stats.lastProbeAtMs),
            ])
            probes[app]?.isUnsaved = false
        }
        catch {
            // Kept in memory: this run follows the result anyway, and the next save retries.
            log.error("Failed to save page reading probes: \(String(describing: error), privacy: .public)")
        }
    }

    /// The server's table, or nothing if it doesn't exist (yet). Rows with unknown values are skipped.
    private func loadChoices() throws -> [AppIdentity: Choice] {
        let tables = try db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").run([.text(Self.choiceTable)])
        guard !tables.isEmpty else {
            return [:]
        }
        let rows = try db.prepare("""
            SELECT identifier_type, identifier, page_reading_choice, reprobe_requested_at_ms FROM \(Self.choiceTable)
            """).run()
        var result: [AppIdentity: Choice] = [:]
        for row in rows {
            guard let app = Self.app(row[0], row[1]), let choice = row[2].int.flatMap(PageReadingChoice.init(rawValue:)) else {
                log.warning("Skipping invalid row in \(Self.choiceTable, privacy: .public)")
                continue
            }
            result[app] = Choice(choice: choice, reprobeRequestedAtMs: row[3].int)
        }
        log.info("Loaded \(result.count) page reading choices")
        return result
    }

    private static func app(_ type: SQLValue, _ identifier: SQLValue) -> AppIdentity? {
        guard let type = type.int.flatMap(AppIdentifierType.init(rawValue:)), case .text(let identifier) = identifier else {
            return nil
        }
        return AppIdentity(type: type, identifier: identifier)
    }
}
