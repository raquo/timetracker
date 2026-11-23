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

/// Decides per app whether to read its pages, and finds out by probing for apps nobody has
/// decided on. See "Adaptive page reading" in notes/PLAN.md.
///
/// - The user's choice (see `PageReadingStore`) wins unless it's auto.
/// - Else the probe result. On: a probe saw a content page. Off: no probe saw one during
///   `evidenceMs` of active use, counted within this run. Probe counts are saved only now and
///   then (`saveAll`), not on every probe.
/// - Else probing.
///
/// Confined to the tracker's queue.
final class PageReadingPolicy {
    /// Active use without a content page after which the probe result is off.
    static let evidenceMs: Int64 = 30 * 60 * 1000
    /// Each step between samples adds at most this much, so sleep, hangs and clock jumps add ~nothing.
    static let maxStepMs: Int64 = 10_000
    /// Probe the same window again after this long. A window other than the one last probed
    /// in that app is probed right away.
    static let probeEveryMs: Int64 = 60_000

    private struct LastSample {
        let app: AppIdentity
        let atMs: Int64
        /// Active, and the app was being probed (probed this run, still undecided after this
        /// sample) and had a window to probe. So the sample that decides doesn't count towards
        /// a later re-probe.
        let isCounted: Bool
    }

    private struct LastProbe {
        let pid: pid_t
        let window: AnyHashable
        let atMs: Int64
    }

    private let store: PageReadingStore
    private var probes: [AppIdentity: AppPageProbes] = [:]
    /// Apps whose probes changed since last saved.
    private var unsaved: Set<AppIdentity> = []
    private var choices: [AppIdentity: AppPageReadingChoice] = [:]

    // Evidence for the off verdict, this run only.
    /// Active time while probing, per app.
    private var activeMs: [AppIdentity: Int64] = [:]
    /// Apps probed at least once since probing started, so their active time counts as evidence.
    private var probedApps: Set<AppIdentity> = []
    private var lastSample: LastSample?
    /// Per app, so switching back to an app doesn't probe its window again before `probeEveryMs`.
    /// Only apps being probed: dropped when decided.
    private var lastProbes: [AppIdentity: LastProbe] = [:]

    init(store: PageReadingStore) throws {
        self.store = store
        probes = try store.loadProbes()
        refresh()
    }

    /// Re-reads the user's choices if another connection wrote to the database. Call once per sample.
    func refresh() {
        do {
            if let changed = try store.choicesIfChanged() {
                choices = changed
            }
        }
        catch {
            log.failure("read page reading choices", error)
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

    /// Whether to probe `window` now: it isn't the window last probed in `app` (or the app was
    /// relaunched), or that was a while ago. `window`: any value that identifies the window.
    func isProbeDue(app: AppIdentity, pid: pid_t, window: AnyHashable, atMs nowMs: Int64) -> Bool {
        guard let last = lastProbes[app], last.pid == pid, last.window == window else {
            return true
        }
        let sinceMs = nowMs - last.atMs
        return sinceMs >= Self.probeEveryMs || sinceMs < 0
    }

    /// A probe of `app`'s focused window found content pages, or not.
    func noteProbe(app: AppIdentity, pid: pid_t, window: AnyHashable, hasContentPages: Bool, atMs nowMs: Int64) {
        lastProbes[app] = LastProbe(pid: pid, window: window, atMs: nowMs)
        var stats = probes[app] ?? AppPageProbes()
        let isFirstProbe = stats.probeCount == 0
        if isFirstProbe {
            stats.firstProbeAtMs = nowMs
        }
        stats.probeCount += 1
        stats.lastProbeAtMs = nowMs
        probes[app] = stats
        unsaved.insert(app)
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
        for app in unsaved {
            save(app)
        }
    }

    /// Counts the time since the previous sample as active use of that sample's app, if it was
    /// active and being probed; decides off once that reaches `evidenceMs`. Call on every sample,
    /// after probing. `app`: the frontmost app, nil if none or the screen is locked.
    /// `hasProbeableWindow`: the app has a focused window and we have the Accessibility
    /// permission, so it could be probed. Time without one isn't evidence: no probe could look.
    func noteSample(app: AppIdentity?, mode: PageReadingMode, isActive: Bool, hasProbeableWindow: Bool, atMs nowMs: Int64) {
        if let last = lastSample, last.isCounted, probedApps.contains(last.app) {
            let stepMs = min(max(nowMs - last.atMs, 0), Self.maxStepMs)
            let totalMs = activeMs[last.app, default: 0] + stepMs
            activeMs[last.app] = totalMs
            if totalMs >= Self.evidenceMs {
                decide(last.app, hasContentPages: false, atMs: nowMs)
            }
        }
        lastSample = app.map { app in
            LastSample(app: app, atMs: nowMs, isCounted: isActive && hasProbeableWindow && mode == .probing && probedApps.contains(app))
        }
    }

    /// Only after at least one probe of `app` (`noteProbe`).
    private func decide(_ app: AppIdentity, hasContentPages: Bool, atMs nowMs: Int64) {
        probes[app]?.hasContentPages = hasContentPages
        probes[app]?.decidedAtMs = nowMs
        unsaved.insert(app)
        activeMs[app] = nil
        probedApps.remove(app)
        lastProbes[app] = nil
        log.info("Page reading probe result for \(app.identifier, privacy: .public): \(hasContentPages ? "has content pages" : "no content pages", privacy: .public)")
        save(app)
    }

    private func save(_ app: AppIdentity) {
        guard let stats = probes[app] else {
            return
        }
        do {
            try store.save(stats, for: app)
            unsaved.remove(app)
        }
        catch {
            // Kept in memory: this run follows the result anyway, and the next save retries.
            log.failure("save page reading probes", error)
        }
    }
}
