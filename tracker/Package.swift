// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TimeTracker",
    // macOS 15: see docs/architecture.md.
    platforms: [.macOS("15.0")],
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
        // Holds the Accessibility permission for the end-to-end tests and does only what needs it.
        // Bundled and signed by scripts/e2e.sh.
        .executableTarget(name: "E2EHelper"),
        // End-to-end: the real tracker against E2ETarget. Skipped unless run by scripts/e2e.sh.
        .testTarget(
            name: "TrackerE2ETests",
            dependencies: ["TrackerCore"]
        ),
    ]
)
