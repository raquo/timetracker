import AppKit
import ApplicationServices

/// Switches on the web Accessibility tree of Electron apps (`AXManualAccessibility`), which they
/// build only when asked, and then keep up to date on every page change until they quit, which
/// has a cost. Browsers and native apps with web views expose their pages without a switch.
/// See docs/page-reading.md.
///
/// We never switch the tree back off: we can't tell whether something else started relying on
/// it while we ran (see TODO "Tracker: Accessibility tree in other apps" in notes/PLAN.md).
/// It goes off when the app quits.
///
/// Confined to the tracker's queue.
final class ElectronTreeSwitch {
    /// One run of an app. A pid alone isn't enough: once the app quits, macOS can give its pid
    /// to a later app, which would then never get its tree switched on.
    private struct AppRun: Hashable {
        let pid: pid_t
        /// nil for a process not launched through LaunchServices (rare for an app).
        let launchDate: Date?
    }

    /// Apps whose tree we've switched on this run.
    private var enabledRuns: Set<AppRun> = []
    /// Whether the bundle at each path is an Electron app.
    private var electronBundles: [String: Bool] = [:]
    /// The launch date of the app running with this pid, nil if none (or unknown).
    private let launchDate: (pid_t) -> Date?

    init(launchDate: @escaping (pid_t) -> Date? = { NSRunningApplication(processIdentifier: $0)?.launchDate }) {
        self.launchDate = launchDate
    }

    /// Switches the tree on if the app is an Electron app and we haven't yet. The tree is built
    /// asynchronously, so the first searches after that may find nothing.
    func enableIfElectron(app: AXUIElement, pid: pid_t, bundlePath: String?) {
        enableIfElectron(pid: pid, bundlePath: bundlePath) {
            app.set(AxName.manualAccessibility, true)
        }
    }

    /// `switchOn`: sets the flag on the app. Separate for tests.
    func enableIfElectron(pid: pid_t, bundlePath: String?, switchOn: () -> AXError) {
        guard isElectron(bundlePath: bundlePath) else {
            return
        }
        let run = AppRun(pid: pid, launchDate: launchDate(pid))
        guard !enabledRuns.contains(run) else {
            return
        }
        // Prune apps that quit, or whose pid went to another app.
        enabledRuns = enabledRuns.filter { launchDate($0.pid) == $0.launchDate }
        let result = switchOn()
        if result == .success {
            enabledRuns.insert(run)
            log.info("Enabled Accessibility tree for pid \(pid)")
        }
        else {
            log.warning("Could not enable Accessibility tree for pid \(pid): \(result.rawValue)")
        }
    }

    /// Electron apps ship `Electron Framework.framework`, whatever they're called.
    private func isElectron(bundlePath: String?) -> Bool {
        guard let bundlePath else {
            return false
        }
        if let cached = electronBundles[bundlePath] {
            return cached
        }
        let framework = bundlePath + "/Contents/Frameworks/Electron Framework.framework"
        let isElectron = FileManager.default.fileExists(atPath: framework)
        electronBundles[bundlePath] = isElectron
        return isElectron
    }
}
