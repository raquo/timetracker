import Foundation
import os

let log = Logger(subsystem: "timetracker.tracker", category: "tracker")

/// Current time in Unix epoch milliseconds. Always Int64, never Int32 or seconds:
/// see "Timestamps" in notes/PLAN.md.
func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}
