import AppKit
import Foundation

extension E2E {
    /// The running `E2EHelper` (scripts/e2e.sh builds and signs it): does what needs the
    /// Accessibility permission, which the test process can't have (docs/end-to-end-tests.md).
    final class Helper {
        let bundleUrl: URL
        var pid: pid_t?
        private let commands: CommandFiles

        init(bundleUrl: URL, controlDir: URL) {
            self.bundleUrl = bundleUrl
            commands = CommandFiles(dir: controlDir, name: "E2E Helper")
        }

        /// Starts it in the background, as its own app: macOS then checks its permission, not
        /// that of the terminal that ran `swift test`. Fails at once, saying what to do, unless
        /// it has the permission.
        func start() async throws {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = false
            config.arguments = ["--control", commands.dir.path]
            pid = try await NSWorkspace.shared.openApplication(at: bundleUrl, configuration: config).processIdentifier
            let answer = try await commands.send("checkAccess", [:]) as? [String: Any]
            guard answer?["isTrusted"] as? Bool == true else {
                throw E2EError("E2E Helper has no Accessibility permission. Once: System Settings → Privacy & Security → Accessibility → + → add \(bundleUrl.path) and switch it on, then run again.")
            }
        }

        /// Moves keyboard focus to the address bar of Chrome's focused window; returns once Chrome
        /// reports it there. Sets focus on that one element: no keystrokes or clicks.
        func focusAddressBar(pid chromePid: pid_t?) async throws {
            guard let chromePid else {
                throw E2EError("Chrome isn't running")
            }
            try await commands.send("focusAddressBar", ["pid": Int(chromePid)])
        }

        /// Moves keyboard focus to the page showing `url` in the focused window of the app with
        /// this pid; returns once the app reports focus in it. Gets focus out of Chrome's address
        /// bar.
        func focusPage(pid appPid: pid_t?, url: String) async throws {
            guard let appPid else {
                throw E2EError("the app isn't running")
            }
            try await commands.send("focusPage", ["pid": Int(appPid), "url": url])
        }
    }
}
