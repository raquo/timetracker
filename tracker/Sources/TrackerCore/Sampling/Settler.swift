/// Holds back a changed sample until a second sample confirms it, so a row never records an
/// in-between state: a browser that has committed the new URL but not yet the new title, or the
/// moment mid-switch between two apps or tabs (consistency #1 in docs/record-consistency.md).
///
/// The confirmed row starts when the change was first seen, not when it was confirmed, so
/// settling delays the write but doesn't move boundaries. A state that never settles (a title
/// changing several times a second) is recorded once `maxSettleMs` has passed: the latest state
/// seen in two samples, else the last one seen. A sample read mid-change (consistency #3) is
/// almost never repeated, so it isn't recorded even then.
///
/// A change seen before a gap in sampling (sleep, a hang, a suspended process) isn't carried
/// across it: after the gap it counts as first seen again, so its row can't span the gap.
///
/// Confined to the tracker's queue.
final class Settler {
    /// How long after a change to sample again.
    static let resampleDelayMs = 400
    /// Two samples closer than this don't confirm each other: both may be mid-change.
    static let minConfirmGapMs: Int64 = 250
    static let maxSettleMs: Int64 = 3_000
    /// Samples further apart than this have a gap between them (see `Recorder.maxGapMs`).
    static let maxGapMs = Recorder.maxGapMs

    enum Decision: Equatable {
        /// Record this sample. If it starts a new row, the row starts at `changedAtMs`.
        case record(changedAtMs: Int64)
        /// Record `snapshot`, seen in earlier samples, instead of this one, from `changedAtMs`;
        /// then sample again after `resampleDelayMs`, since this sample is still unconfirmed.
        /// Only when a change hasn't settled after `maxSettleMs`.
        case recordEarlier(Snapshot, idleSinceMs: Int64?, changedAtMs: Int64)
        /// Don't record yet; sample again after `resampleDelayMs`.
        case wait
    }

    private struct Seen {
        let snapshot: Snapshot
        let idleSinceMs: Int64?
        let atMs: Int64
    }

    private struct Pending {
        let snapshot: Snapshot
        /// The first sample that differed from the recorded row.
        let firstSeenMs: Int64
        /// The first sample with `snapshot`: equal samples after it don't move it, so two
        /// confirm each other only if they're far enough apart.
        let sampledAtMs: Int64
    }

    private var pending: Pending?
    /// Every sample since `pending.firstSeenMs`, oldest first, for the fallback at `maxSettleMs`.
    private var history: [Seen] = []
    private var lastSampleMs: Int64?

    /// `recorded`: the snapshot of the open row, nil when there is none.
    /// `idleSinceMs`: the sample's, handed back if its snapshot is recorded later (`recordEarlier`).
    func decide(_ snapshot: Snapshot, idleSinceMs: Int64?, atMs nowMs: Int64, recorded: Snapshot?) -> Decision {
        defer {
            lastSampleMs = nowMs
        }
        if let lastSampleMs, nowMs - lastSampleMs > Self.maxGapMs {
            // A change seen before the gap isn't carried across it.
            reset()
        }
        if snapshot == recorded {
            // Unchanged, or a change that reverted before it was confirmed.
            reset()
            return .record(changedAtMs: nowMs)
        }
        let seen = Seen(snapshot: snapshot, idleSinceMs: idleSinceMs, atMs: nowMs)
        guard let current = pending else {
            pending = Pending(snapshot: snapshot, firstSeenMs: nowMs, sampledAtMs: nowMs)
            history = [seen]
            return .wait
        }
        history.append(seen)
        let isConfirmed = snapshot == current.snapshot && nowMs - current.sampledAtMs >= Self.minConfirmGapMs
        // A clock jump backwards makes the difference negative: record rather than wait forever.
        let settleMs = nowMs - current.firstSeenMs
        let changedAtMs = min(current.firstSeenMs, nowMs)
        if isConfirmed || settleMs < 0 {
            reset()
            return .record(changedAtMs: changedAtMs)
        }
        if settleMs >= Self.maxSettleMs {
            guard let earlier = latestSeenTwice(), earlier.snapshot != snapshot else {
                reset()
                return .record(changedAtMs: changedAtMs)
            }
            // This sample stays pending: it may be the state that settles next.
            pending = Pending(snapshot: snapshot, firstSeenMs: nowMs, sampledAtMs: nowMs)
            history = [seen]
            return .recordEarlier(earlier.snapshot, idleSinceMs: earlier.idleSinceMs, changedAtMs: changedAtMs)
        }
        if snapshot != current.snapshot {
            pending = Pending(snapshot: snapshot, firstSeenMs: current.firstSeenMs, sampledAtMs: nowMs)
        }
        return .wait
    }

    /// Drops an unconfirmed change, e.g. before closing the row on sleep or quit.
    func reset() {
        pending = nil
        history = []
    }

    /// The latest sample whose snapshot an earlier sample, at least `minConfirmGapMs` before it,
    /// also showed: a state that held on screen, not one read mid-change.
    private func latestSeenTwice() -> Seen? {
        for (i, later) in history.enumerated().reversed() {
            let isSeenBefore = history[..<i].contains { earlier in
                earlier.snapshot == later.snapshot && later.atMs - earlier.atMs >= Self.minConfirmGapMs
            }
            if isSeenBefore {
                return later
            }
        }
        return nil
    }
}
