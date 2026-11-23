import Testing
@testable import TrackerCore

struct RecorderTests {
    private let a = Fixtures.youtube
    private let b = Fixtures.hackerNews
    private let h: RecorderHarness

    init() throws {
        h = try RecorderHarness()
    }

    @Test func constants() {
        #expect(Recorder.maxGapMs == 20_000)
        #expect(Recorder.flushEveryMs == 30_000)
    }

    @Test func firstSampleOpensAZeroLengthRowOnDisk() throws {
        try h.record(a, at: 0)
        #expect(try h.rows() == [row(a, 0, 0)])
        #expect(h.recorder.openSnapshot == a)
    }

    @Test func unchangedSamplesExtendTheRowInMemoryAndFlushEvery30s() throws {
        try h.record(a, at: 0)
        for at in stride(from: Int64(5_000), through: 25_000, by: 5_000) {
            try h.record(a, at: at)
            #expect(try h.rows() == [row(a, 0, 0)], "not flushed at +\(at)")
        }
        try h.record(a, at: 30_000)
        #expect(try h.rows() == [row(a, 0, 30_000)])
        try h.record(a, at: 35_000)
        try h.record(a, at: 55_000)
        #expect(try h.rows() == [row(a, 0, 30_000)])
        // 30 s after the last flush, not on a 30 s grid.
        try h.record(a, at: 59_999)
        #expect(try h.rows() == [row(a, 0, 30_000)])
        try h.record(a, at: 60_000)
        #expect(try h.rows() == [row(a, 0, 60_000)])
    }

    @Test func changeEndsTheRowWhereTheNewOneStarts() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 5_000)
        try h.record(b, at: 7_400, changedAt: 7_000)
        #expect(try h.rows() == [row(a, 0, 7_000), row(b, 7_000, 7_400)])
        #expect(h.recorder.openSnapshot == b)
    }

    @Test func oldRowHoldsAtLeastUntilItsLastSample() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 5_000)
        // Seen changing before a's last sample: the boundary stays at that sample.
        try h.record(b, at: 5_400, changedAt: 4_000)
        #expect(try h.rows() == [row(a, 0, 5_000), row(b, 5_000, 5_400)])
    }

    @Test func changeAtTheRowsStartReplacesIt() throws {
        try h.record(a, at: 0)
        try h.record(b, at: 400, changedAt: 0)
        #expect(try h.rows() == [row(b, 0, 400)])
    }

    @Test func goingIdleBackdatesToTheLastInput() throws {
        for at in stride(from: Int64(0), through: 65_000, by: 5_000) {
            try h.record(a, at: at)
        }
        #expect(try h.rows() == [row(a, 0, 60_000)])
        // Idle once 60 s pass without input; the last input was at +10 s.
        try h.record(Fixtures.idle(a), at: 70_000, idleSince: 10_000)
        #expect(try h.rows() == [row(a, 0, 10_000), row(Fixtures.idle(a), 10_000, 70_000)])
    }

    @Test func idleBackdatingStopsAtTheRowsStart() throws {
        try h.record(b, at: 0)
        try h.record(a, at: 20_000)
        try h.record(a, at: 25_000)
        // The last input was while b was open: a's row goes, b's isn't touched.
        try h.record(Fixtures.idle(a), at: 30_000, idleSince: 15_000)
        #expect(try h.rows() == [row(b, 0, 20_000), row(Fixtures.idle(a), 20_000, 30_000)])
    }

    @Test func goingIdleWithAChangeKeepsTheOldStateUntilTheChange() throws {
        for at in stride(from: Int64(0), through: 65_000, by: 5_000) {
            try h.record(a, at: at)
        }
        // The first idle sample also shows another page, first seen at +68 s. The old page
        // stayed on screen until then: idle from the last input, but still that page.
        try h.record(Fixtures.idle(b), at: 70_000, changedAt: 68_000, idleSince: 10_000)
        #expect(try h.rows() == [row(a, 0, 10_000), row(Fixtures.idle(a), 10_000, 68_000), row(Fixtures.idle(b), 68_000, 70_000)])
        #expect(h.recorder.openSnapshot == Fixtures.idle(b))
        try h.record(Fixtures.idle(b), at: 75_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 10_000), row(Fixtures.idle(a), 10_000, 68_000), row(Fixtures.idle(b), 68_000, 75_000)])
    }

    @Test func goingIdleWithAChangeStopsAtTheRowsStart() throws {
        try h.record(b, at: 0)
        try h.record(a, at: 20_000)
        try h.record(a, at: 25_000)
        // The last input was while b was open: only a's row turns idle.
        try h.record(Fixtures.idle(b), at: 30_000, idleSince: 15_000)
        #expect(try h.rows() == [row(b, 0, 20_000), row(Fixtures.idle(a), 20_000, 30_000), row(Fixtures.idle(b), 30_000, 30_000)])
    }

    @Test func goingIdleWithAChangeSeenAtTheLastInputNeedsNoIdleOldRow() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 5_000)
        // Last input at +8 s, after the change was first seen at +7 s: the old state never went idle.
        try h.record(Fixtures.idle(b), at: 70_000, changedAt: 7_000, idleSince: 8_000)
        #expect(try h.rows() == [row(a, 0, 7_000), row(Fixtures.idle(b), 7_000, 70_000)])
    }

    @Test func unlockingWithoutInputLeavesTheLockedRowAlone() throws {
        try h.record(a, at: 0)
        try h.record(Fixtures.locked, at: 10_000)
        try h.record(Fixtures.locked, at: 15_000)
        // Unlocked by Apple Watch: no input since before the lock. The screen was locked
        // until now, not idle.
        try h.record(Fixtures.idle(a), at: 600_000, changedAt: 20_000, idleSince: 9_000)
        #expect(try h.rows() == [row(a, 0, 10_000), row(Fixtures.locked, 10_000, 20_000), row(Fixtures.idle(a), 20_000, 600_000)])
    }

    @Test func inputOnTheLockScreenDoesntSplitTheLockedRow() throws {
        try h.record(Fixtures.locked, at: 0)
        try h.record(Fixtures.locked, at: 5_000)
        try h.record(Fixtures.idle(a), at: 10_000, idleSince: 3_000)
        #expect(try h.rows() == [row(Fixtures.locked, 0, 10_000), row(Fixtures.idle(a), 10_000, 10_000)])
    }

    @Test func onlyGoingIdleBackdates() throws {
        let idleA = Fixtures.idle(a)
        let idleB = Fixtures.idle(b)
        try h.record(idleA, at: 0)
        try h.record(idleA, at: 5_000)
        // Idle to idle: the window changed by itself (a video playlist). No backdating.
        try h.record(idleB, at: 10_000, idleSince: -60_000)
        // Idle to active: input just now.
        try h.record(a, at: 15_000, idleSince: -60_000)
        #expect(try h.rows() == [row(idleA, 0, 10_000), row(idleB, 10_000, 15_000), row(a, 15_000, 15_000)])
    }

    @Test func gapOver20sEndsTheRowAtItsLastSample() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 5_000)
        try h.record(a, at: 25_000)  // exactly 20 s: bridged
        try h.record(a, at: 45_001)  // 20.001 s: not
        #expect(try h.rows() == [row(a, 0, 25_000), row(a, 45_001, 45_001)])
    }

    @Test func gapIsMeasuredToWhenAChangeWasFirstSeen() throws {
        try h.record(a, at: 0)
        // 21 s after a's last sample, but first seen exactly 20 s after it: bridged.
        try h.record(b, at: 21_000, changedAt: 20_000)
        // First seen 20.001 s after b's last sample: not.
        try h.record(a, at: 42_000, changedAt: 41_001)
        #expect(try h.rows() == [row(a, 0, 20_000), row(b, 20_000, 21_000), row(a, 41_001, 42_000)])
    }

    @Test func clockGoingBackPausesUntilItCatchesUp() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 10_000)
        try h.record(a, at: 4_000)
        #expect(try h.rows() == [row(a, 0, 10_000)])
        #expect(h.recorder.openSnapshot == nil)
        try h.record(b, at: 9_999)
        #expect(try h.rows() == [row(a, 0, 10_000)])
        #expect(h.recorder.openSnapshot == nil)
        try h.record(b, at: 10_000, changedAt: 9_000)
        try h.record(b, at: 15_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 10_000), row(b, 10_000, 15_000)])
    }

    @Test func watermarkSurvivesARestart() throws {
        for at in stride(from: Int64(0), through: 50_000, by: 10_000) {
            try h.record(a, at: at)
        }
        try h.close()
        try h.restart()
        try h.record(b, at: 40_000)
        #expect(h.recorder.openSnapshot == nil)
        try h.record(b, at: 60_000, changedAt: 45_000)
        #expect(try h.rows() == [row(a, 0, 50_000), row(b, 50_000, 60_000)])
    }

    @Test func closeWritesTheLastSample() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 12_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 12_000)])
        #expect(h.recorder.openSnapshot == nil)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 12_000)])
    }

    @Test func closeWritesOnlyWhatChanged() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 15_000)
        try h.record(a, at: 30_000)
        #expect(try h.rows() == [row(a, 0, 30_000)])
        let before = try h.temp.totalChanges()
        try h.close()
        #expect(try h.temp.totalChanges() == before)
        #expect(try h.rows() == [row(a, 0, 30_000)])
    }

    @Test func closeDeletesAZeroLengthRow() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 5_000)
        try h.record(b, at: 5_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 5_000)])
    }

    @Test func afterCloseTheSameSnapshotStartsANewRow() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 5_000)
        try h.close()
        // Woken 1 s later, with the same window: a new row, not bridged.
        try h.record(a, at: 6_000)
        try h.record(a, at: 8_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 5_000), row(a, 6_000, 8_000)])
    }

    @Test func storesEverySnapshotField() throws {
        var full = Fixtures.notes
        full.windowSubrole = "AXDialog"
        full.isMainWindow = false
        full.isFullScreen = true
        full.url = "https://example.com/"
        full.pageTitle = "Example"
        var partial = Snapshot(bundleID: "com.example.Panel", appName: "Panel", bundlePath: "/Applications/Panel.app")
        partial.windowRole = "AXWindow"
        try h.record(full, at: 0)
        try h.record(partial, at: 1_000)
        try h.record(Fixtures.locked, at: 2_000)
        try h.close()
        let rows = try h.rows()
        #expect(rows == [row(full, 0, 1_000), row(partial, 1_000, 2_000)])
        // Spelled out once, in case the expected-row builder is wrong too.
        #expect(rows[0] == StoredInterval(
            startMs: t0, endMs: t0 + 1_000,
            app: StoredApp(type: .bundleID, identifier: "com.apple.TextEdit", path: "/System/Applications/TextEdit.app", name: "TextEdit"),
            windowTitle: "notes.txt", documentPath: "/Users/someone/notes.txt",
            url: "https://example.com/", pageTitle: "Example",
            windowRole: "AXWindow", windowSubrole: "AXDialog",
            isIdle: false, isScreenLocked: false, isMainWindow: false, isFullScreen: true
        ))
        #expect(rows[1].windowSubrole == "")
        #expect(rows[1].isMainWindow == nil && rows[1].isFullScreen == nil)
    }

    @Test func storesALockedScreenWithNothingElse() throws {
        try h.record(Fixtures.locked, at: 0)
        try h.record(Fixtures.locked, at: 5_000)
        try h.close()
        #expect(try h.rows() == [StoredInterval(
            startMs: t0, endMs: t0 + 5_000, app: nil, windowTitle: nil, documentPath: nil,
            url: nil, pageTitle: nil, windowRole: nil, windowSubrole: nil,
            isIdle: false, isScreenLocked: true, isMainWindow: nil, isFullScreen: nil
        )])
    }

    @Test func lookupRowsAreShared() throws {
        // A window title that equals another row's page title shares its tracker_title row.
        let c = Fixtures.firefox("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Other", windowTitle: "Video one - YouTube")
        for (i, s) in [a, b, a, c, b].enumerated() {
            try h.record(s, at: Int64(i) * 1_000)
        }
        try h.record(b, at: 5_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 1_000), row(b, 1_000, 2_000), row(a, 2_000, 3_000), row(c, 3_000, 4_000), row(b, 4_000, 5_000)])
        let ids = try h.temp.db.query("SELECT app_id, title_id, page_title_id, url_id, window_role_id FROM tracker_interval ORDER BY start_ms")
        // The same snapshot gets the same IDs.
        #expect(ids[0] == ids[2])
        #expect(ids[1] == ids[4])
        // c: a's URL, and a's page title as its window title.
        #expect(ids[3][3] == ids[0][3])
        #expect(ids[3][1] == ids[0][2])
        #expect(ids[3][2] != ids[0][2])
        #expect(Set(ids.map { $0[0].int! }).count == 1)
        #expect(Set(ids.map { $0[4].int! }).count == 1)
        #expect(try h.temp.count("tracker_app") == 1)
        #expect(try h.temp.count("tracker_url") == 2)
        #expect(try h.temp.count("tracker_window_role") == 1)
        // Window and page titles of a and b, plus "Other".
        #expect(try h.temp.count("tracker_title") == 5)
    }

    @Test func appRows() throws {
        var renamed = a
        renamed.appName = "Firefox"
        var moved = a
        moved.bundlePath = "/Users/someone/Applications/Firefox Developer Edition.app"
        let tool = Snapshot(executablePath: "/usr/local/bin/tool")
        try h.record(a, at: 0)
        try h.record(renamed, at: 1_000)
        try h.record(moved, at: 2_000)
        let panel = Snapshot(bundleID: "com.example.Panel", bundlePath: "/Applications/Panel.app")
        try h.record(tool, at: 3_000)
        try h.record(panel, at: 4_000)
        try h.record(panel, at: 5_000)
        try h.close()
        let apps = try h.temp.db.query("SELECT identifier_type, identifier, app_path, name FROM tracker_app ORDER BY id")
        #expect(apps == [
            // Renaming updates the row in place; a new location is another row.
            [.int(0), .text("org.mozilla.firefoxdeveloperedition"), .text("/Applications/Firefox Developer Edition.app"), .text("Firefox")],
            [.int(0), .text("org.mozilla.firefoxdeveloperedition"), .text("/Users/someone/Applications/Firefox Developer Edition.app"), .text("Firefox Developer Edition")],
            // No bundle: identified by the executable, named after it.
            [.int(1), .text("/usr/local/bin/tool"), .text("/usr/local/bin/tool"), .text("tool")],
            // No name from macOS: named after the bundle, extension and all.
            [.int(0), .text("com.example.Panel"), .text("/Applications/Panel.app"), .text("Panel.app")],
        ])
        let appIDs = try h.temp.db.query("SELECT app_id FROM tracker_interval ORDER BY start_ms").map { $0[0].int! }
        try #require(appIDs.count == 5)
        #expect(appIDs[0] == appIDs[1])
        #expect(Set(appIDs).count == 4)
    }
}

/// Settler and recorder together, as the tracker runs them.
struct PipelineTests {
    private let a = Fixtures.youtube
    private let b = Fixtures.hackerNews
    private let h: RecorderHarness

    init() throws {
        h = try RecorderHarness()
    }

    @Test func tabSwitchWithURLBeforeTitleGivesTwoRows() throws {
        let bHalf = Fixtures.firefox(b.url, a.pageTitle)
        try h.tick(a, at: 0)
        try h.tick(a, at: 400)
        try h.tick(a, at: 5_400)
        try h.tick(bHalf, at: 6_000)
        try h.tick(b, at: 6_400)
        try h.tick(b, at: 6_800)
        try h.tick(b, at: 11_800)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 6_000), row(b, 6_000, 11_800)])
    }

    @Test func flickerLeavesOneRow() throws {
        try h.tick(a, at: 0)
        try h.tick(a, at: 400)
        try h.tick(b, at: 3_000)
        try h.tick(a, at: 3_400)
        try h.tick(a, at: 8_400)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 8_400)])
    }

    @Test func changeSettlingWhenSamplingStopsDoesntSpanTheGap() throws {
        try h.tick(a, at: 0)
        try h.tick(a, at: 400)
        try h.tick(a, at: 5_000)
        try h.tick(b, at: 6_000)
        // Nothing for 114 s (asleep, or hung), then b again.
        try h.tick(b, at: 120_000)
        try h.tick(b, at: 120_400)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 5_000), row(b, 120_000, 120_400)])
    }

    @Test func sleepHandlerRunningOnlyAfterWakeEndsAtTheLastSample() throws {
        // macOS doesn't wait for the sleep handler: its last sample may come after wake.
        try h.tick(a, at: 0)
        try h.tick(a, at: 400)
        try h.tick(a, at: 5_000)
        try h.tick(b, at: 6_000)
        try h.closeInterval(b, at: 120_000)
        #expect(try h.rows() == [row(a, 0, 5_000)])
        // After wake, b is recorded from when it's confirmed again.
        try h.tick(b, at: 121_000)
        try h.tick(b, at: 121_400)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 5_000), row(b, 121_000, 121_400)])
    }

    @Test func closeIntervalTakesALastSample() throws {
        try h.tick(a, at: 0)
        try h.tick(a, at: 400)
        try h.closeInterval(a, at: 4_000)
        #expect(try h.rows() == [row(a, 0, 4_000)])
    }

    @Test func goingIdleThroughTheSettlerBackdatesToTheLastInput() throws {
        for at in stride(from: Int64(0), through: 65_000, by: 5_000) {
            try h.tick(a, at: at)
        }
        let idleA = Fixtures.idle(a)
        try h.tick(idleA, at: 70_000, idleSince: 10_000)
        // The first tick waited, so the row opened at +5 s and was flushed at +35 s and +65 s.
        #expect(try h.rows() == [row(a, 0, 65_000)])
        try h.tick(idleA, at: 70_400, idleSince: 10_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 10_000), row(idleA, 10_000, 70_400)])
    }

    @Test func goingIdleWithAChangeThroughTheSettler() throws {
        for at in stride(from: Int64(0), through: 65_000, by: 5_000) {
            try h.tick(a, at: at)
        }
        let idleB = Fixtures.idle(b)
        try h.tick(idleB, at: 70_000, idleSince: 10_000)
        try h.tick(idleB, at: 70_400, idleSince: 10_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 10_000), row(Fixtures.idle(a), 10_000, 70_000), row(idleB, 70_000, 70_400)])
    }

    @Test func unlockingWithoutInputThroughTheSettler() throws {
        try h.tick(a, at: 0)
        try h.tick(a, at: 5_000)
        for at in stride(from: Int64(10_000), through: 600_000, by: 5_000) {
            try h.tick(Fixtures.locked, at: at)
        }
        let idleA = Fixtures.idle(a)
        try h.tick(idleA, at: 602_000, idleSince: 9_000)
        try h.tick(idleA, at: 602_400, idleSince: 9_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 10_000), row(Fixtures.locked, 10_000, 602_000), row(idleA, 602_000, 602_400)])
    }

    @Test func unconfirmedChangeAtCloseIsDropped() throws {
        try h.tick(a, at: 0)
        try h.tick(a, at: 400)
        try h.tick(a, at: 5_400)
        try h.tick(b, at: 6_000)
        try h.close()
        #expect(try h.rows() == [row(a, 0, 5_400)])
    }
}

/// What `Recorder` promises when a write fails: rows stay valid, and the next sample retries.
struct RecorderWriteFailureTests {
    private let a = Fixtures.youtube
    private let b = Fixtures.hackerNews
    private let h: RecorderHarness

    init() throws {
        h = try RecorderHarness()
    }

    @Test func failedFlushIsRetriedNotMistakenForAGap() throws {
        for at in stride(from: Int64(0), through: 25_000, by: 5_000) {
            try h.record(a, at: at)
        }
        try h.temp.failWrites("UPDATE")
        #expect(throws: SQLiteError.self) {
            try h.record(a, at: 30_000)
        }
        try h.temp.restoreWrites()
        #expect(try h.rows() == [row(a, 0, 0)])
        #expect(h.recorder.openSnapshot == a)
        try h.record(a, at: 35_000)
        #expect(try h.rows() == [row(a, 0, 35_000)])
    }

    @Test func failedIdleOldRowLeavesAGapNotAnOverlap() throws {
        for at in stride(from: Int64(0), through: 65_000, by: 5_000) {
            try h.record(a, at: at)
        }
        try h.temp.failWrites("INSERT")
        #expect(throws: SQLiteError.self) {
            try h.record(Fixtures.idle(b), at: 70_000, idleSince: 10_000)
        }
        try h.temp.restoreWrites()
        // The old row was closed at the last input; nothing after it.
        #expect(try h.rows() == [row(a, 0, 10_000)])
        #expect(h.recorder.openSnapshot == nil)
        try h.record(Fixtures.idle(b), at: 75_000)
        #expect(try h.rows() == [row(a, 0, 10_000), row(Fixtures.idle(b), 75_000, 75_000)])
    }

    @Test func failedEndOfTheOldRowKeepsItOpenForTheNextSample() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 10_000)
        try h.temp.failWrites("UPDATE")
        #expect(throws: SQLiteError.self) {
            try h.record(b, at: 12_000)
        }
        try h.temp.restoreWrites()
        #expect(h.recorder.openSnapshot == a)
        try h.record(b, at: 12_400, changedAt: 12_000)
        #expect(try h.rows() == [row(a, 0, 12_000), row(b, 12_000, 12_400)])
    }

    @Test func failedInsertLeavesAGapNeverAnOverlap() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 10_000)
        try h.temp.failWrites("INSERT")
        #expect(throws: SQLiteError.self) {
            try h.record(b, at: 12_000)
        }
        try h.temp.restoreWrites()
        #expect(try h.rows() == [row(a, 0, 12_000)])
        #expect(h.recorder.openSnapshot == nil)
        // First seen before a's row ended: starts where a ended instead.
        try h.record(b, at: 12_400, changedAt: 11_000)
        #expect(try h.rows() == [row(a, 0, 12_000), row(b, 12_000, 12_400)])
    }

    @Test func failedCloseIsRetried() throws {
        try h.record(a, at: 0)
        try h.record(a, at: 5_000)
        try h.temp.failWrites("UPDATE")
        #expect(throws: SQLiteError.self) {
            try h.close()
        }
        try h.temp.restoreWrites()
        #expect(h.recorder.openSnapshot == a)
        try h.close()
        #expect(h.recorder.openSnapshot == nil)
        #expect(try h.rows() == [row(a, 0, 5_000)])
    }

    @Test func failedDeleteOfAZeroLengthRowIsRetried() throws {
        try h.record(a, at: 0)
        try h.temp.failWrites("DELETE")
        #expect(throws: SQLiteError.self) {
            try h.close()
        }
        try h.temp.restoreWrites()
        #expect(try h.rows() == [row(a, 0, 0)])
        try h.close()
        #expect(try h.rows() == [])
    }
}
