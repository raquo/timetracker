import AppKit
import os

/// The process entry point: parses the command line, then either runs a diagnostic or starts
/// the tracker and the app's run loop.
///
/// - `TimeTracker`: track, into `databasePath()`.
/// - `TimeTracker --dump-ax <bundle-id> <output-file>`: see `AXDump`.
public enum TrackerMain {
    enum Command: Equatable {
        case track
        case dumpAX(bundleID: String, outputPath: String)
        /// `--dump-ax` with the wrong arguments.
        case usageError
    }

    static let usage = "usage: TimeTracker [--dump-ax <bundle-id> <output-file>]"

    /// Other arguments are ignored: macOS and Xcode may add their own (`-NSDocumentRevisionsDebugMode YES`).
    static func command(arguments: [String]) -> Command {
        guard arguments.count >= 2, arguments[1] == "--dump-ax" else {
            return .track
        }
        if arguments.count == 4 {
            return .dumpAX(bundleID: arguments[2], outputPath: arguments[3])
        }
        else {
            return .usageError
        }
    }

    public static func run(arguments: [String]) -> Never {
        switch command(arguments: arguments) {
        case .track:
            break
        case .dumpAX(let bundleID, let outputPath):
            exit(AXDump.run(bundleID: bundleID, outputPath: outputPath))
        case .usageError:
            // Not tracking instead: the mistake would go unnoticed.
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(2)
        }

        let path: String
        do {
            path = try databasePath()
            guard try InstanceLock.acquire(databasePath: path) else {
                // Exit 0: under launchd (KeepAlive) this instance is retried every ThrottleInterval,
                // so it takes over if the other one goes away.
                announce("another tracker is already recording to \(path); exiting", level: .default)
                exit(0)
            }
        }
        catch {
            fail("startup failed: \(error)")
        }

        let tracker: Tracker
        do {
            let db = try Database(path: path)
            try Schema.migrate(db)
            tracker = try Tracker(db: db)
            log.info("Using database at \(path, privacy: .public)")
        }
        catch {
            fail("startup failed: \(error)")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        tracker.start()
        // A local may be released after its last use; the tracker must outlive the run loop.
        withExtendedLifetime(tracker) {
            app.run()
        }
        exit(0)
    }

    /// `TIMETRACKER_DB` overrides the database path, for testing.
    static func databasePath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["TIMETRACKER_DB"], !override.isEmpty {
            return override
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("com.raquo.timetracker", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timetracker.db").path
    }

    /// Logs `message` and also prints it to stderr, for runs from a terminal.
    private static func announce(_ message: String, level: OSLogType) {
        log.log(level: level, "\(message, privacy: .public)")
        FileHandle.standardError.write(Data("Time Tracker: \(message)\n".utf8))
    }

    private static func fail(_ message: String) -> Never {
        announce(message, level: .fault)
        exit(1)
    }
}
