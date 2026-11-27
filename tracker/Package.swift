// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TimeTracker",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything but the entry point, so tests can import it.
        .target(
            name: "TrackerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TimeTracker",
            dependencies: ["TrackerCore"]
        ),
        .testTarget(
            name: "TrackerCoreTests",
            dependencies: ["TrackerCore"],
            // Read from the source tree (`#filePath`), not bundled.
            exclude: ["Fixtures"]
        ),
        // The app the end-to-end tests drive. Bundled by scripts/e2e.sh, not installed.
        .executableTarget(name: "E2ETarget"),
        // End-to-end: the real tracker against E2ETarget. Skipped unless run by scripts/e2e.sh.
        .testTarget(
            name: "TrackerE2ETests",
            dependencies: ["TrackerCore"]
        ),
    ]
)
