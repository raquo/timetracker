/// The raw attributes of one moment. Consecutive equal snapshots merge into one interval.
struct Snapshot: Equatable {
    var bundleId: String? = nil
    var appName: String? = nil
    /// The .app bundle's path, or nil for a process without one.
    var bundlePath: String? = nil
    var executablePath: String? = nil
    var windowTitle: String? = nil
    /// AXRole / AXSubrole of the focused window. Tells panels and popups apart from normal windows.
    var windowRole: String? = nil
    var windowSubrole: String? = nil
    /// nil: not reported (no focused window, or no Accessibility permission).
    var isMainWindow: Bool? = nil
    var isFullScreen: Bool? = nil
    var documentPath: String? = nil
    /// URL and title of the page in the focused window's web content (apps whose pages are read,
    /// see `PageReadingPolicy`).
    var pageUrl: String? = nil
    var pageTitle: String? = nil
    var isInputIdle = false
    var isScreenLocked = false

    /// The app, as the user thinks of it. nil when there's no frontmost app (screen locked) or
    /// macOS gave neither a bundle ID nor an executable path.
    var app: AppIdentity? {
        AppIdentity(bundleId: bundleId, executablePath: executablePath)
    }
}
