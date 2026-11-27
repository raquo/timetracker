import Testing
@testable import TrackerCore

/// Steps through samples as the tracker does: a `.record` makes the sample the recorded one.
struct SettlerTests {
    private typealias D = Settler.Decision

    private let a = Fixtures.youtube
    private let b = Fixtures.hackerNews
    /// The in-between state while switching from a to b: new URL, old title.
    private let bHalf = Fixtures.firefox(Fixtures.hackerNews.pageUrl, Fixtures.youtube.pageTitle)

    private struct Step {
        let snapshot: Snapshot
        let atMs: Int64
        let expected: Settler.Decision
    }

    private func step(_ s: Snapshot, _ offsetMs: Int64, _ expected: D) -> Step {
        Step(snapshot: s, atMs: t0 + offsetMs, expected: expected)
    }

    /// Runs `steps` from `recorded`; returns what's recorded at the end.
    @discardableResult
    private func run(_ steps: [Step], recorded initial: Snapshot?, settler: Settler = Settler()) -> Snapshot? {
        var recorded = initial
        for (i, step) in steps.enumerated() {
            let decision = settler.decide(step.snapshot, idleSinceMs: nil, atMs: step.atMs, recorded: recorded)
            #expect(decision == step.expected, "step \(i) at +\(step.atMs - t0) ms")
            switch decision {
            case .record:
                recorded = step.snapshot
            case .recordEarlier(let earlier, _, _):
                recorded = earlier
            case .wait:
                break
            }
        }
        return recorded
    }

    @Test func constants() {
        #expect(Settler.resampleDelayMs == 400)
        #expect(Settler.minConfirmGapMs == 250)
        #expect(Settler.maxSettleMs == 3_000)
        #expect(Settler.maxGapMs == Recorder.maxGapMs)
    }

    @Test func unchangedSampleRecordsAtOnce() {
        run([
            step(a, 0, .record(changedAtMs: t0)),
            step(a, 5_000, .record(changedAtMs: t0 + 5_000)),
        ], recorded: a)
    }

    @Test func firstSampleWithNothingRecordedWaitsToo() {
        run([
            step(a, 0, .wait),
            step(a, 400, .record(changedAtMs: t0)),
        ], recorded: nil)
    }

    @Test func changeIsRecordedFromWhenItWasFirstSeen() {
        let end = run([
            step(b, 0, .wait),
            step(b, 400, .record(changedAtMs: t0)),
            step(b, 5_000, .record(changedAtMs: t0 + 5_000)),
        ], recorded: a)
        #expect(end == b)
    }

    @Test func confirmationNeedsSamplesAtLeast250MsApart() {
        run([
            step(b, 0, .wait),
            step(b, 100, .wait),
            step(b, 249, .wait),
            // Measured from the first sample of this snapshot, not the latest.
            step(b, 250, .record(changedAtMs: t0)),
        ], recorded: a)
    }

    @Test func inBetweenStateNeverGetsItsOwnRow() {
        // The URL changes before the title: the half-switched state is held back, and the
        // settled state is recorded from when the first change was seen.
        let end = run([
            step(bHalf, 0, .wait),
            step(b, 400, .wait),
            step(b, 600, .wait),
            step(b, 650, .record(changedAtMs: t0)),
        ], recorded: a)
        #expect(end == b)
    }

    @Test func changeThatRevertsIsDropped() {
        run([
            step(b, 0, .wait),
            step(a, 400, .record(changedAtMs: t0 + 400)),
            // Nothing pending is left over: a later change starts afresh.
            step(b, 800, .wait),
            step(b, 1_000, .wait),
            step(b, 1_050, .record(changedAtMs: t0 + 800)),
        ], recorded: a)
    }

    @Test func stateThatNeverSettlesIsRecordedAsLastSeenAfter3s() {
        var steps = (0..<8).map { i in
            step(Fixtures.firefox("https://example.com/timer", "0:0\(i)"), Int64(i) * 400, .wait)
        }
        let last = Fixtures.firefox("https://example.com/timer", "0:08")
        steps.append(step(last, 2_999, .wait))
        steps.append(step(last, 3_000, .record(changedAtMs: t0)))
        let end = run(steps, recorded: a)
        #expect(end == last)
    }

    /// Titles that tick every 400 ms, each one different: never seen twice.
    private func ticking(_ i: Int) -> Snapshot {
        Fixtures.firefox("https://example.com/timer", "0:0\(i)")
    }

    @Test func unsettledStateSeenTwiceIsRecordedOverASampleReadMidChange() {
        // b keeps coming back between ticks; the sample at the cap is a mixed one (b's URL with
        // a's title), which no other sample shows. b is recorded instead, from the first change.
        let end = run([
            step(b, 0, .wait),
            step(ticking(1), 400, .wait),
            step(b, 800, .wait),
            step(ticking(2), 1_200, .wait),
            step(ticking(3), 1_600, .wait),
            step(ticking(4), 2_000, .wait),
            step(ticking(5), 2_400, .wait),
            step(ticking(6), 2_800, .wait),
            step(bHalf, 3_000, .recordEarlier(b, idleSinceMs: nil, changedAtMs: t0)),
            // b is the open row now, so b again just continues it.
            step(b, 3_400, .record(changedAtMs: t0 + 3_400)),
        ], recorded: a)
        #expect(end == b)
    }

    @Test func latestOfSeveralStatesSeenTwiceWins() {
        run([
            step(b, 0, .wait),
            step(Fixtures.notes, 400, .wait),
            step(b, 800, .wait),
            step(Fixtures.notes, 1_200, .wait),
            step(ticking(1), 1_600, .wait),
            step(ticking(2), 2_000, .wait),
            step(ticking(3), 2_400, .wait),
            step(ticking(4), 2_800, .wait),
            step(bHalf, 3_000, .recordEarlier(Fixtures.notes, idleSinceMs: nil, changedAtMs: t0)),
        ], recorded: a)
    }

    @Test func sampleAtTheCapSeenBeforeIsRecordedAsItself() {
        run([
            step(b, 0, .wait),
            step(ticking(1), 400, .wait),
            step(ticking(2), 800, .wait),
            step(ticking(3), 1_200, .wait),
            step(ticking(4), 1_600, .wait),
            step(ticking(5), 2_000, .wait),
            step(ticking(6), 2_400, .wait),
            step(ticking(7), 2_800, .wait),
            step(b, 3_000, .record(changedAtMs: t0)),
        ], recorded: a)
    }

    @Test func seenTwiceNeedsSamplesAtLeast250MsApart() {
        // b's two samples are too close to show it held, so the cap falls back to the last one seen.
        let end = run([
            step(b, 0, .wait),
            step(b, 100, .wait),
            step(ticking(1), 400, .wait),
            step(ticking(2), 800, .wait),
            step(ticking(3), 1_200, .wait),
            step(ticking(4), 1_600, .wait),
            step(ticking(5), 2_000, .wait),
            step(ticking(6), 2_400, .wait),
            step(ticking(7), 2_800, .wait),
            step(bHalf, 3_000, .record(changedAtMs: t0)),
        ], recorded: a)
        #expect(end == bHalf)
    }

    @Test func sampleLeftPendingByTheFallbackCanSettle() {
        // After b is recorded, the mixed sample is a new pending change of its own, first seen at
        // the cap; if it holds, it's confirmed like any other.
        let end = run([
            step(b, 0, .wait),
            step(ticking(1), 400, .wait),
            step(b, 800, .wait),
            step(ticking(2), 1_200, .wait),
            step(bHalf, 3_000, .recordEarlier(b, idleSinceMs: nil, changedAtMs: t0)),
            step(bHalf, 3_400, .record(changedAtMs: t0 + 3_000)),
        ], recorded: a)
        #expect(end == bHalf)
    }

    @Test func fallbackHandsBackTheEarlierSamplesIdleTime() {
        let settler = Settler()
        let idleB = Fixtures.idle(b)
        #expect(settler.decide(idleB, idleSinceMs: t0 - 70_000, atMs: t0, recorded: a) == .wait)
        #expect(settler.decide(ticking(1), idleSinceMs: nil, atMs: t0 + 400, recorded: a) == .wait)
        #expect(settler.decide(idleB, idleSinceMs: t0 - 69_000, atMs: t0 + 800, recorded: a) == .wait)
        #expect(settler.decide(bHalf, idleSinceMs: nil, atMs: t0 + 3_000, recorded: a) == .recordEarlier(idleB, idleSinceMs: t0 - 69_000, changedAtMs: t0))
    }

    @Test func clockJumpBackRecordsAtTheEarlierTime() {
        run([
            step(b, 0, .wait),
            step(b, -1_000, .record(changedAtMs: t0 - 1_000)),
        ], recorded: a)
    }

    @Test func changeSeenBeforeAGapStartsAfreshAfterIt() {
        run([
            step(b, 0, .wait),
            // 20.001 s later: a gap. b counts as first seen now, so it needs confirming again.
            step(b, 20_001, .wait),
            step(b, 20_200, .wait),
            step(b, 20_251, .record(changedAtMs: t0 + 20_001)),
        ], recorded: a)
    }

    @Test func exactly20sIsNotAGap() {
        run([
            step(b, 0, .wait),
            step(b, 20_000, .record(changedAtMs: t0)),
        ], recorded: a)
    }

    @Test func gapIsMeasuredFromTheLastSampleOfAnyKind() {
        run([
            step(b, 0, .wait),
            step(Fixtures.notes, 2_900, .wait),
            // 19.1 s after the last sample, 22 s after the change was first seen: not a gap,
            // so the change keeps its first sighting (and has long passed maxSettleMs).
            step(Fixtures.notes, 22_000, .record(changedAtMs: t0)),
        ], recorded: a)
    }

    @Test func unchangedSampleAfterAGapRecordsAtOnce() {
        // The recorder sees the gap itself.
        run([
            step(a, 0, .record(changedAtMs: t0)),
            step(a, 60_000, .record(changedAtMs: t0 + 60_000)),
        ], recorded: a)
    }

    @Test func resetDropsThePendingChange() {
        let settler = Settler()
        run([step(b, 0, .wait)], recorded: a, settler: settler)
        settler.reset()
        run([
            step(b, 400, .wait),
            step(b, 800, .record(changedAtMs: t0 + 400)),
        ], recorded: a, settler: settler)
    }

    @Test func idleAndLockAreChangesLikeAnyOther() {
        run([
            step(Fixtures.idle(a), 0, .wait),
            step(Fixtures.idle(a), 400, .record(changedAtMs: t0)),
            step(Fixtures.locked, 1_000, .wait),
            step(Fixtures.locked, 1_400, .record(changedAtMs: t0 + 1_000)),
        ], recorded: a)
    }
}
