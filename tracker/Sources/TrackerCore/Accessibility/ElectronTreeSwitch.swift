import AppKit
import ApplicationServices

/// Switches on the web Accessibility tree of Electron apps (`AXManualAccessibility`), which they
/// build only when asked, and then keep up to date on every page change until they quit, which
/// has a cost. Browsers and native apps with web views expose their pages without a switch.
/// See notes/electron-and-claude.md.
///
/// We never switch the tree back off: we can't tell whether something else started relying on
/// it while we ran (see TODO "Tracker: Accessibility tree in other apps" in notes/PLAN.md).
/// It goes off when the app quits.
///
/// Confined to the tracker's queue.
final class ElectronTreeSwitch {
    /// Apps whose tree we've switched on this run.
    private var enabledPIDs: Set<pid_t> = []
    /// Whether the bundle at each path is an Electron app.
    private var electronBundles: [String: Bool] = [:]

    /// Switches the tree on if the app is an Electron app and we haven't yet. The tree is built
    /// asynchronously, so the first searches after that may find nothing.
    func enableIfElectron(app: AXUIElement, pid: pid_t, bundlePath: String?) {
        guard isElectron(bundlePath: bundlePath), !enabledPIDs.contains(pid) else {
            return
        }
        // Prune apps that quit (pids can be reused).
        enabledPIDs = enabledPIDs.filter { NSRunningApplication(processIdentifier: $0) != nil }
        let result = app.set(AXName.manualAccessibility, true)
        if result == .success {
            enabledPIDs.insert(pid)
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
