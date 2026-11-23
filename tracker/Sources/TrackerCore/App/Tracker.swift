import AppKit
import ApplicationServices

/// Wires macOS events and a backstop poll to the sampler and recorder.
/// All state is confined to `queue`, so a slow app's Accessibility API never blocks the main thread.
final class Tracker {
    /// Backstop only: app switches and window/title changes arrive as events.
    /// The poll catches what events miss, and idle / unidle transitions.
    static let pollIntervalSeconds = 5

    /// Coalesces bursts of change events (e.g. a page updating its title repeatedly).
    static let eventDelayMs = 300

    /// After a click, wait this long before sampling, so the app has time to react
    /// (e.g. switch the conversation or tab that was clicked).
    static let clickDelayMs = 600

    private enum DelayedTick {
        case event
        case click
        case settle

        var delayMs: Int {
            switch self {
            case .event: Tracker.eventDelayMs
            case .click: Tracker.clickDelayMs
            case .settle: Settler.resampleDelayMs
            }
        }
    }

    private let queue = DispatchQueue(label: "timetracker.tracker")
    private let recorder: Recorder
    private let sampler: Sampler
    private let pageReading: PageReadingPolicy
    private let settler = Settler()
    private let windowObserver: WindowObserver
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var clickMonitor: Any?

    // Confined to `queue`.
    private var isScreenLocked = false
    private var isAsleep = false
    private var isAxTrusted: Bool?
    private var scheduledTicks: Set<DelayedTick> = []

    init(db: Database) throws {
        recorder = try Recorder(store: IntervalStore(db: db))
        pageReading = try PageReadingPolicy(store: PageReadingStore(db: db))
        sampler = Sampler(pageReading: pageReading)
        windowObserver = WindowObserver(queue: queue)
        windowObserver.onChange = { [weak self] in
            self?.scheduleTick(.event)
        }
    }

    func start() {
        Accessibility.setGlobalTimeout()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.tick() }
        // macOS doesn't wait for this, so the final sample may not happen before sleep. Then the
        // next sample, after wake, sees the gap and ends the interval at the last sample instead.
        observe(workspace, NSWorkspace.willSleepNotification) { tracker in
            tracker.closeInterval()
            tracker.isAsleep = true
        }
        observe(workspace, NSWorkspace.didWakeNotification) { tracker in
            tracker.isAsleep = false
            tracker.tick()
        }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { tracker in
            tracker.isScreenLocked = true
            tracker.tick()
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { tracker in
            tracker.isScreenLocked = false
            tracker.tick()
        }

        // Any click anywhere triggers a sample: catches changes that send no Accessibility event
        // (e.g. clicking another conversation in Claude). Only the fact of a click is used, never
        // its position or target. Needs the Accessibility permission; a no-op without it.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else {
                return
            }
            self.queue.async { self.scheduleTick(.click) }
        }

        // Started while locked (launchd relaunching after a crash): no lock notification comes
        // then, only the unlock one. Queued before the timer, so the first sample sees it.
        queue.async { [self] in
            isScreenLocked = Self.isScreenLockedNow()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(Self.pollIntervalSeconds), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in
                log.info("Received signal \(sig), closing interval and exiting")
                self?.closeInterval()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        // Only an app bundle can hold the permission; a bare binary would attribute the prompt to its terminal.
        if Bundle.main.bundleIdentifier != nil {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        log.info("Tracker started")
    }

    private func tick() {
        guard !isAsleep else {
            return
        }
        let isAxTrusted = checkAccessibility()
        let now = nowMs()
        let sample = sampler.sample(nowMs: now, isScreenLocked: isScreenLocked, isAxTrusted: isAxTrusted)
        windowObserver.observe(pid: sample.frontmostPID, watchFocusedElement: sample.isReadingPages, isAxTrusted: isAxTrusted)
        windowObserver.watchPage(sample.pageElement)
        switch settler.decide(sample.snapshot, atMs: now, recorded: recorder.openSnapshot) {
        case .record(let changedAtMs):
            do {
                try recorder.record(sample.snapshot, idleSinceMs: sample.idleSinceMs, atMs: now, changedAtMs: changedAtMs)
            }
            catch {
                log.failure("record sample", error)
            }
        case .wait:
            scheduleTick(.settle)
        }
    }

    /// Ticks after `kind`'s delay. Further requests of the same kind until then are absorbed by it.
    private func scheduleTick(_ kind: DelayedTick) {
        guard scheduledTicks.insert(kind).inserted else {
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(kind.delayMs)) { [weak self] in
            self?.scheduledTicks.remove(kind)
            self?.tick()
        }
    }

    /// Takes a final sample, so the time since the last poll isn't lost, then closes the open interval.
    /// A change seen by that sample can't be confirmed any more, so it's dropped.
    private func closeInterval() {
        tick()
        settler.reset()
        pageReading.saveAll()
        do {
            try recorder.close()
        }
        catch {
            log.failure("close interval", error)
        }
    }

    /// Whether the screen is locked right now, from the login session's state.
    private static func isScreenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Whether we have the Accessibility permission. Logs when that changes.
    private func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isAxTrusted {
            if trusted {
                log.info("Accessibility permission granted")
            }
            else {
                log.warning("No Accessibility permission: window titles and document paths won't be recorded")
            }
            isAxTrusted = trusted
        }
        return trusted
    }

    /// Runs `handler` on the queue for each `name` notification.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Tracker) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else {
                return
            }
            self.queue.async { handler(self) }
        }
        observers.append((center, token))
    }
}
