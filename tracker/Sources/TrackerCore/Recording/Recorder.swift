import Foundation

/// Turns a stream of samples into `tracker_interval` rows (written through `IntervalStore`).
///
/// The open interval lives in memory and its `end_ms` is flushed every `flushEveryMs`,
/// so a crash loses at most that much time and every row on disk is always valid.
///
/// Writes are separate autocommit statements, not one transaction: closing the previous row
/// must not depend on the lookups and insert for the next one succeeding. A failure between
/// them leaves a gap (the next sample opens a new row), never an overlap or a stale row.
final class Recorder {
    /// Samples further apart than this mean the tracker wasn't running (sleep, suspension, crash),
    /// so the interval ends at the last sample instead of stretching across the gap.
    static let maxGapMs: Int64 = 20_000  // 4 polls
    static let flushEveryMs: Int64 = 30_000

    private struct OpenInterval {
        let rowId: Int64
        let snapshot: Snapshot
        let startMs: Int64
        var endMs: Int64
        var flushedEndMs: Int64
    }

    private let store: IntervalStore
    private var open: OpenInterval?

    /// Latest `end_ms` of any closed row. New rows never start before it, so rows never overlap,
    /// even when the wall clock jumps backwards (see "Watermark" in docs/record-consistency.md).
    private var watermarkMs: Int64
    private var isClockBehind = false

    init(store: IntervalStore) throws {
        self.store = store
        watermarkMs = try store.latestEndMs()
    }

    /// The open row's snapshot, nil when there is none.
    var openSnapshot: Snapshot? {
        open?.snapshot
    }

    /// `changedAtMs`: when the change to this snapshot was first seen (see `Settler`); a new row
    /// starts there. At most `nowMs`. `idleSinceMs`: see `Sample`.
    func record(_ snapshot: Snapshot, idleSinceMs: Int64?, atMs nowMs: Int64, changedAtMs: Int64) throws {
        if var current = open {
            // The open row was last seen at `endMs`; the next sample is now, or for a change, when it was first seen.
            let nextSeenMs = current.snapshot == snapshot ? nowMs : changedAtMs
            if nowMs < current.endMs || nextSeenMs - current.endMs > Self.maxGapMs {
                // Clock went backwards, or we missed samples: don't bridge the gap.
                try close()
            }
            else if current.snapshot == snapshot {
                current.endMs = nowMs
                // Kept in memory before flushing: a failed flush must not look like a gap next time.
                open = current
                if nowMs - current.flushedEndMs >= Self.flushEveryMs {
                    try store.setEnd(nowMs, rowId: current.rowId)
                    open?.flushedEndMs = nowMs
                }
                return
            }
            else {
                // The old state held at least until its last sample.
                let boundaryMs = min(nowMs, max(current.endMs, changedAtMs))
                // Going idle: the idle stretch really started at the last input, so the old row
                // ends there. If something else changed too, the old state stayed on screen,
                // idle, until the change was seen: that gets a row of its own. Not from a locked
                // screen (unlocked without input, by Apple Watch): it was locked all along.
                var oldEndMs = boundaryMs
                var idleOld: Snapshot? = nil
                if snapshot.isInputIdle, !current.snapshot.isInputIdle, !current.snapshot.isScreenLocked, let idleSinceMs {
                    oldEndMs = min(boundaryMs, max(current.startMs, idleSinceMs))
                    var wentIdle = current.snapshot
                    wentIdle.isInputIdle = true
                    if wentIdle != snapshot, oldEndMs < boundaryMs {
                        idleOld = wentIdle
                    }
                }
                // Close first, on its own. If this throws, `open` is kept and the next sample retries.
                if oldEndMs <= current.startMs {
                    try store.delete(rowId: current.rowId)
                }
                else {
                    try store.setEnd(oldEndMs, rowId: current.rowId)
                }
                watermarkMs = max(watermarkMs, oldEndMs)
                open = nil
                var newStartMs = oldEndMs
                if let idleOld {
                    _ = try store.insert(idleOld, startMs: oldEndMs, endMs: boundaryMs)
                    watermarkMs = max(watermarkMs, boundaryMs)
                    newStartMs = boundaryMs
                }
                open = try insert(snapshot, startMs: newStartMs, endMs: nowMs)
                return
            }
        }
        guard nowMs >= watermarkMs else {
            // The clock is behind time we've already recorded. Record nothing until it catches up.
            if !isClockBehind {
                isClockBehind = true
                log.warning("Clock is \(self.watermarkMs - nowMs) ms behind recorded data; pausing until it catches up")
            }
            return
        }
        if isClockBehind {
            isClockBehind = false
            log.info("Clock caught up with recorded data; recording again")
        }
        let startMs = min(nowMs, max(watermarkMs, changedAtMs))
        open = try insert(snapshot, startMs: startMs, endMs: nowMs)
    }

    /// Ends the open interval at the last sample. Call on sleep and on quit.
    /// If the write fails, the interval stays open and the next call retries.
    func close() throws {
        guard let current = open else {
            return
        }
        if current.endMs == current.startMs {
            // Opened by the last sample before closing: no duration, so no row.
            try store.delete(rowId: current.rowId)
        }
        else if current.endMs != current.flushedEndMs {
            try store.setEnd(current.endMs, rowId: current.rowId)
        }
        watermarkMs = max(watermarkMs, current.endMs)
        open = nil
    }

    private func insert(_ s: Snapshot, startMs: Int64, endMs: Int64) throws -> OpenInterval {
        let rowId = try store.insert(s, startMs: startMs, endMs: endMs)
        return OpenInterval(rowId: rowId, snapshot: s, startMs: startMs, endMs: endMs, flushedEndMs: endMs)
    }
}
