/// Holds back a changed sample until a second sample confirms it, so a row never records an
/// in-between state: a browser that has committed the new URL but not yet the new title, or the
/// moment mid-switch between two apps or tabs (consistency #1 in notes/PLAN.md).
///
/// The confirmed row starts when the change was first seen, not when it was confirmed, so
/// settling delays the write but doesn't move boundaries. A state that never settles (a title
/// ticking every second) is recorded as last seen once `maxSettleMs` has passed.
///
/// Confined to the tracker's queue.
final class Settler {
    /// How long after a change to sample again.
    static let resampleDelayMs = 400
    /// Two samples closer than this don't confirm each other: both may be mid-change.
    static let minConfirmGapMs: Int64 = 250
    static let maxSettleMs: Int64 = 3_000

    enum Decision {
        /// Record the sample. If it starts a new row, the row starts at `changedAtMs`.
        case record(changedAtMs: Int64)
        /// Don't record yet; sample again after `resampleDelayMs`.
        case wait
    }

    private struct Pending {
        let snapshot: Snapshot
        /// The first sample that differed from the recorded row.
        let firstSeenMs: Int64
        /// The latest sample with `snapshot`.
        let sampledAtMs: Int64
    }

    private var pending: Pending?

    /// `recorded`: the snapshot of the open row, nil when there is none.
    func decide(_ snapshot: Snapshot, atMs nowMs: Int64, recorded: Snapshot?) -> Decision {
        if snapshot == recorded {
            // Unchanged, or a change that reverted before it was confirmed.
            pending = nil
            return .record(changedAtMs: nowMs)
        }
        guard let current = pending else {
            pending = Pending(snapshot: snapshot, firstSeenMs: nowMs, sampledAtMs: nowMs)
            return .wait
        }
        let isConfirmed = snapshot == current.snapshot && nowMs - current.sampledAtMs >= Self.minConfirmGapMs
        // A clock jump backwards makes the difference negative: record rather than wait forever.
        let settleMs = nowMs - current.firstSeenMs
        if isConfirmed || settleMs >= Self.maxSettleMs || settleMs < 0 {
            pending = nil
            return .record(changedAtMs: min(current.firstSeenMs, nowMs))
        }
        if snapshot != current.snapshot {
            pending = Pending(snapshot: snapshot, firstSeenMs: current.firstSeenMs, sampledAtMs: nowMs)
        }
        return .wait
    }

    /// Drops an unconfirmed change, e.g. before closing the row on sleep or quit.
    func reset() {
        pending = nil
    }
}
