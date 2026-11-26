import Foundation
import os

let log = Logger(subsystem: "timetracker.tracker", category: "tracker")

extension Logger {
    /// Logs an operation that failed without stopping the tracker: "Failed to <action>: <error>".
    func failure(_ action: String, _ error: Error) {
        self.error("Failed to \(action, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}

/// Current time in Unix epoch milliseconds. Always Int64, never Int32 or seconds:
/// see "Timestamps and durations" in docs/conventions.md.
func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
