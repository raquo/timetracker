import Foundation
@testable import TrackerCore

/// A fixed point in time, far from 0, so a fresh database's watermark (0) never matters.
let t0: Int64 = 1_800_000_000_000

/// Realistic snapshots, as the sampler builds them.
enum Fixtures {
    static func firefox(_ url: String?, _ pageTitle: String?, windowTitle: String? = nil) -> Snapshot {
        Snapshot(
            bundleID: "org.mozilla.firefoxdeveloperedition",
            appName: "Firefox Developer Edition",
            bundlePath: "/Applications/Firefox Developer Edition.app",
            executablePath: "/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox",
            windowTitle: windowTitle ?? pageTitle.map { "\($0) — Firefox Developer Edition" },
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow",
            isMainWindow: true,
            isFullScreen: false,
            url: url,
            pageTitle: pageTitle
        )
    }

    static let youtube = firefox("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Video one - YouTube")
    static let hackerNews = firefox("https://news.ycombinator.com/item?id=1", "Some story | Hacker News")

    static func textEdit(_ path: String) -> Snapshot {
        Snapshot(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            bundlePath: "/System/Applications/TextEdit.app",
            executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
            windowTitle: (path as NSString).lastPathComponent,
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow",
            isMainWindow: true,
            isFullScreen: false,
            documentPath: path
        )
    }

    static let notes = textEdit("/Users/someone/notes.txt")

    /// `s`, idle.
    static func idle(_ s: Snapshot) -> Snapshot {
        var idle = s
        idle.isIdle = true
        return idle
    }

    static let locked = Snapshot(isScreenLocked: true)
}
