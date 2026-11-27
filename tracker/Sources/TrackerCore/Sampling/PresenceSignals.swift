import AppKit

/// Signals that the user may be at the Mac without touching it: something holding off display
/// sleep (a video, a presentation, a call), the camera or mic in use. For the server's away rule.
/// Every field is nil when not measured: a failed read, or the screen is locked.
struct PresenceSignals: Equatable {
    /// Processes holding an assertion that keeps the display awake (`PreventUserIdleDisplaySleep`),
    /// and why (the assertion's name). Empty: none.
    var displaySleepHolders: Set<SignalHolder>? = nil
    var isCameraInUse: Bool? = nil
    /// Processes with input running from an audio device (a mic; an audio tap alone doesn't count).
    /// Empty: none.
    var micHolders: Set<SignalHolder>? = nil
}

/// One holder of a presence signal.
struct SignalHolder: Hashable {
    /// The process the signal is for. nil when it couldn't be identified (it already exited).
    var app: ProcessApp?
    /// The process that holds it on `app`'s behalf (caffeinate), if any. Display sleep only.
    var via: ProcessApp? = nil
    /// The power assertion's name, as the app gave it. nil for the mic.
    var reason: String? = nil
}

/// A process, identified as a `tracker_app` row: like the frontmost app, its bundle if it has
/// one, else its executable.
struct ProcessApp: Hashable {
    let identity: AppIdentity
    /// The .app bundle's path, or the executable's path when there is none. '' if unknown.
    let appPath: String
    /// nil: derived from the path when stored.
    let name: String?

    init(identity: AppIdentity, appPath: String, name: String?) {
        self.identity = identity
        self.appPath = appPath
        self.name = name
    }

    /// nil when the process is gone, or macOS gives neither a bundle ID nor a path for it.
    init?(pid: pid_t) {
        if let running = NSRunningApplication(processIdentifier: pid),
           let identity = AppIdentity(bundleId: running.bundleIdentifier, executablePath: running.executableURL?.path) {
            self.init(identity: identity, appPath: running.bundleURL?.path ?? running.executableURL?.path ?? "", name: running.localizedName)
            return
        }
        // Daemons and command-line tools (caffeinate) may have no NSRunningApplication.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        let path = String(cString: buffer)
        guard !path.isEmpty else {
            return nil
        }
        self.init(identity: AppIdentity(type: .executablePath, identifier: path), appPath: path, name: nil)
    }
}
