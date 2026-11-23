import Testing
@testable import TrackerCore

/// A recorder on a temporary database, driven with times relative to `t0`.
final class RecorderHarness {
    let temp: TempDatabase
    private(set) var recorder: Recorder
    let settler = Settler()

    init(temp: TempDatabase? = nil) throws {
        self.temp = try temp ?? TempDatabase()
        recorder = try Recorder(store: IntervalStore(db: self.temp.db))
    }

    /// Straight to the recorder. `changedAt` defaults to `at`.
    func record(_ s: Snapshot, at: Int64, changedAt: Int64? = nil, idleSince: Int64? = nil) throws {
        try recorder.record(s, idleSinceMs: idleSince.map { t0 + $0 }, atMs: t0 + at, changedAtMs: t0 + (changedAt ?? at))
    }

    /// Through the settler first, as `Tracker.tick` does.
    func tick(_ s: Snapshot, at: Int64, idleSince: Int64? = nil) throws {
        if case .record(let changedAtMs) = settler.decide(s, atMs: t0 + at, recorded: recorder.openSnapshot) {
            try recorder.record(s, idleSinceMs: idleSince.map { t0 + $0 }, atMs: t0 + at, changedAtMs: changedAtMs)
        }
    }

    /// As `Tracker.closeInterval`, minus its last sample.
    func close() throws {
        settler.reset()
        try recorder.close()
    }

    /// As `Tracker.closeInterval`: one last sample, then close.
    func closeInterval(_ s: Snapshot, at: Int64, idleSince: Int64? = nil) throws {
        try tick(s, at: at, idleSince: idleSince)
        try close()
    }

    /// A new recorder on the same database, as after a restart.
    func restart() throws {
        recorder = try Recorder(store: IntervalStore(db: temp.db))
    }

    /// The rows on disk. Also checks that they never overlap and never run backwards.
    func rows(sourceLocation: SourceLocation = #_sourceLocation) throws -> [StoredInterval] {
        let rows = try temp.intervals(sourceLocation: sourceLocation)
        for (i, row) in rows.enumerated() {
            #expect(row.startMs <= row.endMs, "row \(i) runs backwards: \(row)", sourceLocation: sourceLocation)
            if i > 0 {
                #expect(rows[i - 1].endMs <= row.startMs, "rows \(i - 1) and \(i) overlap", sourceLocation: sourceLocation)
            }
        }
        return rows
    }
}

/// The row `s` should have from `t0 + start` to `t0 + end`.
func row(_ s: Snapshot, _ start: Int64, _ end: Int64) -> StoredInterval {
    StoredInterval(s, t0 + start, t0 + end)
}
