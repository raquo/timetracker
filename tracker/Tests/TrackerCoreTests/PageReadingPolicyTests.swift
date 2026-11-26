import Testing
@testable import TrackerCore

struct PageReadingPolicyTests {
    private let notion = AppIdentity(type: .bundleId, identifier: "notion.id")
    private let vscode = AppIdentity(type: .bundleId, identifier: "com.microsoft.VSCode")
    private let tool = AppIdentity(type: .executablePath, identifier: "/usr/local/bin/tool")
    private let h: PolicyHarness

    private static let evidenceMs = PageReadingPolicy.evidenceMs

    init() throws {
        h = try PolicyHarness()
    }

    @Test func constants() {
        #expect(PageReadingPolicy.evidenceMs == 30 * 60 * 1000)
        #expect(PageReadingPolicy.maxStepMs == 10_000)
        #expect(PageReadingPolicy.probeEveryMs == 60_000)
    }

    @Test func newAppIsProbingWithNoRow() throws {
        #expect(h.policy.mode(for: notion) == .probing)
        #expect(h.policy.isProbeDue(app: notion, pid: 100, window: "w1", atMs: t0))
        #expect(try h.probeRows() == [])
    }

    // MARK: Probing to on

    @Test func probeThatFindsAPageTurnsOnAndSavesAtOnce() throws {
        h.probe(notion, at: 0, hasContentPages: false)
        h.probe(notion, at: 60_000, hasContentPages: true)
        #expect(h.policy.mode(for: notion) == .on)
        #expect(try h.probeRows() == [ProbeRow(app: notion, hasContentPages: true, decidedAt: 60_000, count: 2, firstAt: 0, lastAt: 60_000)])
        try h.restart()
        #expect(h.policy.mode(for: notion) == .on)
    }

    @Test func modeOnSamplesDontProbe() throws {
        #expect(h.tick(notion, at: 0, hasContentPages: true) == .probing)
        #expect(h.tick(notion, at: 60_000, window: "w2", hasContentPages: true) == .on)
        #expect(try h.probeRows() == [ProbeRow(app: notion, hasContentPages: true, decidedAt: 0, count: 1, firstAt: 0, lastAt: 0)])
    }

    // MARK: Saving probe counts

    @Test func probesWithoutPagesSaveTheFirstAtOnceTheRestOnSaveAll() throws {
        h.probe(vscode, at: 0)
        #expect(try h.probeRows() == [ProbeRow(app: vscode, hasContentPages: nil, decidedAt: nil, count: 1, firstAt: 0, lastAt: 0)])
        h.probe(vscode, at: 60_000)
        h.probe(vscode, at: 120_000)
        #expect(try h.probeRows() == [ProbeRow(app: vscode, hasContentPages: nil, decidedAt: nil, count: 1, firstAt: 0, lastAt: 0)])
        h.policy.saveAll()
        #expect(try h.probeRows() == [ProbeRow(app: vscode, hasContentPages: nil, decidedAt: nil, count: 3, firstAt: 0, lastAt: 120_000)])
        #expect(h.policy.mode(for: vscode) == .probing)
        // Counts carry on after a restart.
        try h.restart()
        h.probe(vscode, at: 200_000)
        h.policy.saveAll()
        #expect(try h.probeRows() == [ProbeRow(app: vscode, hasContentPages: nil, decidedAt: nil, count: 4, firstAt: 0, lastAt: 200_000)])
    }

    // MARK: When to probe

    @Test func sameWindowIsProbedAgainAfter60s() {
        h.probe(notion, at: 0, window: "w1", pid: 100)
        #expect(!h.policy.isProbeDue(app: notion, pid: 100, window: "w1", atMs: t0))
        #expect(!h.policy.isProbeDue(app: notion, pid: 100, window: "w1", atMs: t0 + 59_999))
        #expect(h.policy.isProbeDue(app: notion, pid: 100, window: "w1", atMs: t0 + 60_000))
        // Another window, a relaunched app (new pid), or a clock jump back: right away.
        #expect(h.policy.isProbeDue(app: notion, pid: 100, window: "w2", atMs: t0 + 1))
        #expect(h.policy.isProbeDue(app: notion, pid: 101, window: "w1", atMs: t0 + 1))
        #expect(h.policy.isProbeDue(app: notion, pid: 100, window: "w1", atMs: t0 - 1))
        // Per app.
        #expect(h.policy.isProbeDue(app: vscode, pid: 100, window: "w1", atMs: t0 + 1))
    }

    @Test func switchingBackToAnAppDoesntProbeItsWindowEarly() {
        h.probe(notion, at: 0, window: "n1")
        h.probe(vscode, at: 10_000, window: "v1")
        #expect(!h.policy.isProbeDue(app: notion, pid: 100, window: "n1", atMs: t0 + 20_000))
    }

    @Test func onlyTheLastProbedWindowIsRemembered() {
        h.probe(notion, at: 0, window: "w1")
        h.probe(notion, at: 10_000, window: "w2")
        #expect(h.policy.isProbeDue(app: notion, pid: 100, window: "w1", atMs: t0 + 20_000))
        #expect(!h.policy.isProbeDue(app: notion, pid: 100, window: "w2", atMs: t0 + 20_000))
    }

    // MARK: Probing to off

    @Test func thirtyMinutesOfActiveUseWithoutAPageTurnsOff() throws {
        var at: Int64 = 0
        while at < Self.evidenceMs {
            #expect(h.tick(vscode, at: at) == .probing)
            at += 5_000
        }
        #expect(h.policy.mode(for: vscode) == .probing)
        // The tick at exactly 30 min probes once more (due every 60 s), then decides.
        #expect(h.tick(vscode, at: Self.evidenceMs) == .probing)
        #expect(h.policy.mode(for: vscode) == .off)
        #expect(try h.probeRows() == [ProbeRow(app: vscode, hasContentPages: false, decidedAt: Self.evidenceMs, count: 31, firstAt: 0, lastAt: Self.evidenceMs)])
        #expect(h.tick(vscode, at: Self.evidenceMs + 60_000) == .off)
        try h.restart()
        #expect(h.policy.mode(for: vscode) == .off)
    }

    @Test func eachStepCountsAtMost10s() {
        h.probe(vscode, at: 0)
        // Samples a minute apart (a hang, or sleep without notice): 10 s each.
        for i in Int64(0)..<180 {
            h.sample(vscode, at: i * 60_000)
        }
        #expect(h.policy.mode(for: vscode) == .probing)
        h.sample(vscode, at: 180 * 60_000)
        #expect(h.policy.mode(for: vscode) == .off)
    }

    @Test func stepsAfterIdleSamplesDontCount() throws {
        h.probe(vscode, at: 0)
        // Alternating active and idle every 5 s: half the time counts.
        var i: Int64 = 0
        while h.policy.mode(for: vscode) == .probing {
            h.sample(vscode, at: i * 5_000, isActive: i % 2 == 0)
            i += 1
        }
        #expect(i - 1 == 719)
        #expect(try h.probeRows().first?.decidedAt == 719 * 5_000)
    }

    @Test func stepsWithoutAWindowOrNotProbingDontCount() throws {
        h.probe(vscode, at: 0)
        var i: Int64 = 0
        while h.policy.mode(for: vscode) == .probing {
            switch i % 3 {
            case 0: h.sample(vscode, at: i * 5_000)
            case 1: h.sample(vscode, at: i * 5_000, hasWindow: false)
            default: h.sample(vscode, at: i * 5_000, mode: .on)
            }
            i += 1
        }
        // One step in three counts: the 360th counted step ends at sample 3 * 359 + 1.
        #expect(i - 1 == 3 * 359 + 1)
    }

    @Test func timeCountsForThePreviousSamplesApp() throws {
        h.probe(vscode, at: 0)
        h.probe(notion, at: 0, window: "n1")
        // vscode, notion, nothing (screen locked), repeating every 5 s.
        var i: Int64 = 0
        while h.policy.mode(for: vscode) == .probing && i < 10_000 {
            h.sample([vscode, notion, nil][Int(i % 3)], at: i * 5_000)
            i += 1
        }
        #expect(i - 1 == 3 * 359 + 1)
        // The loop stopped on a notion sample, so notion has 359 counted steps; the next sample
        // of any app completes its 360th.
        #expect(h.policy.mode(for: notion) == .probing)
        h.sample(notion, at: i * 5_000)
        #expect(h.policy.mode(for: notion) == .off)
    }

    @Test func appNeverProbedThisRunGathersNoEvidence() throws {
        for i in Int64(0)...720 {
            h.sample(vscode, at: i * 5_000)
        }
        #expect(h.policy.mode(for: vscode) == .probing)
        #expect(try h.probeRows() == [])
    }

    @Test func clockGoingBackAddsNothing() throws {
        h.probe(vscode, at: 0)
        h.sample(vscode, at: 0)
        h.sample(vscode, at: 5_000)
        h.sample(vscode, at: -1_000)
        var at: Int64 = -1_000
        while h.policy.mode(for: vscode) == .probing {
            at += 5_000
            h.sample(vscode, at: at)
        }
        #expect(at == -1_000 + Self.evidenceMs - 5_000)
    }

    @Test func evidenceIsNotKeptAcrossRestarts() throws {
        h.probe(vscode, at: 0)
        for i in Int64(0)...300 {
            h.sample(vscode, at: i * 5_000)
        }
        h.policy.saveAll()
        try h.restart()
        h.probe(vscode, at: 2_000_000)
        for i in Int64(0)..<360 {
            h.sample(vscode, at: 2_000_000 + i * 5_000)
        }
        #expect(h.policy.mode(for: vscode) == .probing)
        h.sample(vscode, at: 2_000_000 + 360 * 5_000)
        #expect(h.policy.mode(for: vscode) == .off)
    }

    // MARK: The user's choice

    @Test func choiceTableMayNotExist() {
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .probing)
    }

    @Test func choiceOverridesTheProbeResultOnceRefreshed() throws {
        h.probe(notion, at: 0, hasContentPages: true)
        try h.setChoice(notion, 2)
        #expect(h.policy.mode(for: notion) == .on)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .off)
        try h.setChoice(notion, 1)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .on)
        try h.setChoice(notion, 0)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .on)
        try h.setChoice(vscode, 1)
        try h.setChoice(tool, 2)
        h.policy.refresh()
        #expect(h.policy.mode(for: vscode) == .on)
        #expect(h.policy.mode(for: tool) == .off)
        try h.serverQuery("DELETE FROM app_page_reading_choice")
        h.policy.refresh()
        #expect(h.policy.mode(for: vscode) == .probing)
        #expect(h.policy.mode(for: tool) == .probing)
        // A choice doesn't touch the probe result.
        #expect(try h.probeRows() == [ProbeRow(app: notion, hasContentPages: true, decidedAt: 0, count: 1, firstAt: 0, lastAt: 0)])
    }

    @Test func choiceIsReadAtStartup() throws {
        try h.setChoice(notion, 2)
        try h.restart()
        #expect(h.policy.mode(for: notion) == .off)
    }

    @Test func reprobeRequestedAfterTheResultProbesAgain() throws {
        h.probe(notion, at: 1_000, hasContentPages: true)
        // Not after: no effect.
        try h.setChoice(notion, 0, reprobeAt: 1_000)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .on)
        try h.setChoice(notion, 0, reprobeAt: 1_001)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .probing)
        // The new result is newer than the request.
        #expect(h.tick(notion, at: 5_000, hasContentPages: false) == .probing)
        #expect(h.policy.mode(for: notion) == .probing)
        #expect(h.tick(notion, at: 65_000, hasContentPages: true) == .probing)
        #expect(h.policy.mode(for: notion) == .on)
        #expect(try h.probeRows() == [ProbeRow(app: notion, hasContentPages: true, decidedAt: 65_000, count: 3, firstAt: 1_000, lastAt: 65_000)])
    }

    /// Ticks `app` every 5 s from `from` until its mode isn't probing; returns the last tick's time.
    private func tickUntilDecided(_ app: AppIdentity, from: Int64) -> Int64 {
        var at = from
        while true {
            h.tick(app, at: at)
            if h.policy.mode(for: app) != .probing || at > from + 2 * Self.evidenceMs {
                return at
            }
            at += 5_000
        }
    }

    @Test func reprobeFromOffGathersFreshEvidence() throws {
        #expect(tickUntilDecided(vscode, from: 0) == Self.evidenceMs)
        #expect(h.policy.mode(for: vscode) == .off)
        try h.setChoice(vscode, 0, reprobeAt: Self.evidenceMs + 1)
        // The first tick after the request probes; time before it doesn't count, not even the
        // step from the sample that decided off.
        let start = Self.evidenceMs + 5_000
        #expect(tickUntilDecided(vscode, from: start) == start + Self.evidenceMs)
        #expect(h.policy.mode(for: vscode) == .off)
        // 31 probes before, 31 after (every 60 s, both ends included).
        #expect(try h.probeRows() == [ProbeRow(app: vscode, hasContentPages: false, decidedAt: start + Self.evidenceMs, count: 62, firstAt: 0, lastAt: start + Self.evidenceMs)])
    }

    @Test func reprobeFromOffCanTurnOn() throws {
        #expect(tickUntilDecided(vscode, from: 0) == Self.evidenceMs)
        try h.setChoice(vscode, 0, reprobeAt: Self.evidenceMs + 1)
        #expect(h.tick(vscode, at: Self.evidenceMs + 5_000) == .probing)
        #expect(h.tick(vscode, at: Self.evidenceMs + 10_000, window: "w2", hasContentPages: true) == .probing)
        #expect(h.policy.mode(for: vscode) == .on)
        #expect(try h.probeRows() == [ProbeRow(app: vscode, hasContentPages: true, decidedAt: Self.evidenceMs + 10_000, count: 33, firstAt: 0, lastAt: Self.evidenceMs + 10_000)])
    }

    @Test func reprobeIgnoredWhileOnOrOff() throws {
        h.probe(notion, at: 0, hasContentPages: true)
        try h.setChoice(notion, 2, reprobeAt: 5_000)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .off)
    }

    @Test func choicesAreReReadOnlyWhenAnotherConnectionWrites() throws {
        try h.setChoice(notion, 2)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .off)
        // The tracker's own connection doesn't change `PRAGMA data_version`. (It never writes
        // this table; this shows the choices aren't re-read on every sample.)
        try h.temp.db.query("UPDATE app_page_reading_choice SET page_reading_choice = 1")
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .off)
        // Any write from another connection, to any table, makes the next refresh re-read.
        try h.serverQuery("CREATE TABLE server_other (id INTEGER)")
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .on)
    }

    @Test func brokenChoiceTableKeepsThePreviousChoices() throws {
        try h.setChoice(notion, 2)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .off)
        try h.serverQuery("DROP TABLE app_page_reading_choice")
        try h.serverQuery("CREATE TABLE app_page_reading_choice (identifier_type INTEGER, identifier TEXT, page_reading_choice INTEGER)")
        try h.serverQuery("INSERT INTO app_page_reading_choice VALUES (0, 'notion.id', 1)")
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .off)
        // Fixed: read again on the next change.
        try h.serverQuery("DROP TABLE app_page_reading_choice")
        try h.setChoice(notion, 1)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .on)
    }

    @Test func invalidChoiceRowsAreSkipped() throws {
        try h.setChoice(notion, 7)
        try h.serverQuery("INSERT INTO app_page_reading_choice VALUES (5, 'com.microsoft.VSCode', 2, NULL)")
        try h.setChoice(tool, 2)
        h.policy.refresh()
        #expect(h.policy.mode(for: notion) == .probing)
        #expect(h.policy.mode(for: vscode) == .probing)
        #expect(h.policy.mode(for: tool) == .off)
    }
}
