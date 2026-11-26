import Foundation
import ApplicationServices
import Testing
@testable import TrackerCore

struct IsContentTests {
    private static let claude = "/Applications/Claude.app"
    private static let vscode = "/Applications/Visual Studio Code.app"
    private static let chrome = "/Applications/Google Chrome.app"
    private static let firefox = "/Applications/Firefox Developer Edition.app"

    @Test("Content", arguments: [
        ("https://claude.ai/chat/1f2e3d4c", claude),
        ("http://localhost:3000/", claude),
        // http(s) never counts as the app's own, whatever the path.
        ("https://example.com/Applications/Claude.app/index.html", claude),
        // An app's UI served over https: nothing in the URL tells it apart (Zoom's home screen).
        ("https://new-home-page.localhost/index.html", "/Applications/zoom.us.app"),
        // A local file outside the bundle.
        ("file:///Users/someone/report.html", claude),
        // Only inside the bundle folder, not a sibling with a longer name.
        ("file:///Applications/Claude.app2/index.html", claude),
        // No bundle: nothing is the app's own.
        ("file:///Applications/Claude.app/Contents/Resources/app.asar/index.html", nil),
        // Browsers' own pages, alike in every browser.
        ("chrome://new-tab-page/", chrome),
        ("chrome://accessibility/", chrome),
        ("chrome://mozapps/content/handling/permissionDialog.xhtml", firefox),
        ("about:newtab", firefox),
        ("about:preferences#privacy", firefox),
        ("edge://settings/", "/Applications/Microsoft Edge.app"),
        ("moz-extension://1a2b3c4d/reader.html", firefox),
        // App-private schemes outside the bundle.
        ("app://obsidian.md/index.html", "/Applications/Obsidian.app"),
        ("notion://www.notion.so/abc", "/Applications/Notion.app"),
        ("data:text/html,hello", nil),
        // Only about:blank is a placeholder.
        ("about:srcdoc", firefox),
        ("about:blankish", firefox),
    ] as [(String, String?)])
    func content(url: String, bundlePath: String?) {
        #expect(PageSearch.isContent(URL(string: url)!, bundlePath: bundlePath))
    }

    @Test("Not content", arguments: [
        // The app's own bundle, any scheme but http(s); paths compared percent-decoded.
        ("file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html", claude),
        ("vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-sandbox/workbench/workbench.html", vscode),
        // The empty placeholder, any case.
        ("about:blank", firefox),
        ("ABOUT:BLANK", firefox),
        ("about:blank?x=1", firefox),
        ("about:blank", nil),
    ] as [(String, String?)])
    func notContent(url: String, bundlePath: String?) {
        #expect(!PageSearch.isContent(URL(string: url)!, bundlePath: bundlePath))
    }
}

struct DocumentPathTests {
    @Test(arguments: [
        ("file:///Users/someone/notes.txt", "/Users/someone/notes.txt"),
        ("file:///Users/someone/My%20Notes/caf%C3%A9.md", "/Users/someone/My Notes/café.md"),
        ("file://localhost/Users/someone/a.txt", "/Users/someone/a.txt"),
        // A folder: trailing slash dropped.
        ("file:///Users/someone/Project/", "/Users/someone/Project"),
        // Other URLs (Chrome reports the tab's): scrubbed like page URLs.
        ("https://example.com/doc", "https://example.com/doc"),
        ("https://example.com/reset?token=abc&lang=en#step-2", "https://example.com/reset?token=REDACTED&lang=en"),
        ("https://user:pass@example.com/", "https://REDACTED:REDACTED@example.com/"),
        ("chrome://settings/passwords", "chrome://settings/passwords"),
        ("data:text/html,<h1>secret</h1>", "data:text/html,REDACTED"),
        // Not a URL: kept as reported.
        ("/Users/someone/plain.txt", "/Users/someone/plain.txt"),
        ("/Users/someone/a b?token=x.txt", "/Users/someone/a b?token=x.txt"),
        ("not a url", "not a url"),
        ("", ""),
    ])
    func documentPath(axDocument: String, expected: String) {
        #expect(Sampler.documentPath(fromAxDocument: axDocument) == expected)
    }

    /// Rather not recorded than recorded unscrubbed.
    @Test(arguments: ["data:no-comma", "https://exa mple.com/?token=abc"])
    func unscrubbableUrlIsNotRecorded(axDocument: String) {
        #expect(Sampler.documentPath(fromAxDocument: axDocument) == nil)
    }
}

/// `ElectronTreeSwitch`: switched on once per app run, also when a later app gets the same pid.
struct ElectronTreeSwitchTests {
    private let folder: URL
    private let electronApp: String
    private let nativeApp: String

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ElectronTreeSwitchTests-\(UUID().uuidString)")
        electronApp = folder.appendingPathComponent("Chat.app").path
        nativeApp = folder.appendingPathComponent("Notes.app").path
        try FileManager.default.createDirectory(atPath: electronApp + "/Contents/Frameworks/Electron Framework.framework", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: nativeApp + "/Contents/Frameworks", withIntermediateDirectories: true)
    }

    @Test func switchedOnOncePerAppRun() throws {
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        var running: [pid_t: Date] = [500: Date(timeIntervalSince1970: 1_000)]
        let tree = ElectronTreeSwitch(launchDate: { running[$0] })
        var switchedOn: [pid_t] = []
        let enable = { (pid: pid_t, path: String) in
            tree.enableIfElectron(pid: pid, bundlePath: path) {
                switchedOn.append(pid)
                return .success
            }
        }
        enable(500, electronApp)
        enable(500, electronApp)
        #expect(switchedOn == [500])
        // Not Electron: never.
        enable(600, nativeApp)
        #expect(switchedOn == [500])
        // The app quits and a later one gets its pid.
        running[500] = Date(timeIntervalSince1970: 2_000)
        enable(500, electronApp)
        enable(500, electronApp)
        #expect(switchedOn == [500, 500])
    }

    @Test func failureIsRetried() throws {
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        let tree = ElectronTreeSwitch(launchDate: { _ in Date(timeIntervalSince1970: 1_000) })
        var results: [AXError] = [.cannotComplete, .success]
        var attempts = 0
        for _ in 0..<3 {
            tree.enableIfElectron(pid: 500, bundlePath: electronApp) {
                attempts += 1
                return results.removeFirst()
            }
        }
        #expect(attempts == 2)
    }
}

struct AppIdentityTests {
    @Test func bundleIdWins() {
        #expect(AppIdentity(bundleId: "com.apple.TextEdit", executablePath: "/x/TextEdit") == AppIdentity(type: .bundleId, identifier: "com.apple.TextEdit"))
    }

    @Test func executablePathWithoutBundleId() {
        let expected = AppIdentity(type: .executablePath, identifier: "/usr/local/bin/tool")
        #expect(AppIdentity(bundleId: nil, executablePath: "/usr/local/bin/tool") == expected)
        #expect(AppIdentity(bundleId: "", executablePath: "/usr/local/bin/tool") == expected)
    }

    @Test func neither() {
        #expect(AppIdentity(bundleId: nil, executablePath: nil) == nil)
        #expect(AppIdentity(bundleId: "", executablePath: "") == nil)
        #expect(Snapshot(isScreenLocked: true).app == nil)
    }

    @Test func rawValuesMatchTheSchema() {
        #expect(AppIdentifierType.bundleId.rawValue == 0)
        #expect(AppIdentifierType.executablePath.rawValue == 1)
        #expect(PageReadingChoice.auto.rawValue == 0)
        #expect(PageReadingChoice.on.rawValue == 1)
        #expect(PageReadingChoice.off.rawValue == 2)
    }
}

struct WindowRoleTests {
    @Test func unknownHalvesBecomeEmpty() {
        #expect(WindowRole(role: nil, subrole: nil) == nil)
        #expect(WindowRole(role: "AXWindow", subrole: nil) == WindowRole(role: "AXWindow", subrole: ""))
        let subroleOnly = WindowRole(role: nil, subrole: "AXDialog")
        #expect(subroleOnly?.role == "")
        #expect(subroleOnly?.subrole == "AXDialog")
    }
}

struct CommandLineTests {
    private func command(_ args: String...) -> TrackerMain.Command {
        TrackerMain.command(arguments: ["/Applications/TimeTracker.app/Contents/MacOS/TimeTracker"] + args)
    }

    @Test func parses() {
        #expect(command() == .track)
        #expect(command("--dump-ax", "com.google.Chrome", "/tmp/chrome.json") == .dumpAx(bundleId: "com.google.Chrome", outputPath: "/tmp/chrome.json", format: .text))
        #expect(command("--dump-ax", "com.google.Chrome", "/tmp/chrome.json", "--json") == .dumpAx(bundleId: "com.google.Chrome", outputPath: "/tmp/chrome.json", format: .json))
        // Arguments macOS or Xcode add are ignored.
        #expect(command("-NSDocumentRevisionsDebugMode", "YES") == .track)
        #expect(TrackerMain.command(arguments: []) == .track)
    }

    @Test func dumpAxWithTheWrongArgumentsIsAnError() {
        #expect(command("--dump-ax") == .usageError)
        #expect(command("--dump-ax", "com.google.Chrome") == .usageError)
        #expect(command("--dump-ax", "com.google.Chrome", "/tmp/a.json", "extra") == .usageError)
        #expect(command("--dump-ax", "com.google.Chrome", "/tmp/a.json", "--json", "extra") == .usageError)
    }
}
