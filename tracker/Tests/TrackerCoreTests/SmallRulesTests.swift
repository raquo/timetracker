import Foundation
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
        // Not a file URL: kept as reported.
        ("https://example.com/doc", "https://example.com/doc"),
        ("/Users/someone/plain.txt", "/Users/someone/plain.txt"),
        ("not a url", "not a url"),
        ("", ""),
    ])
    func documentPath(axDocument: String, expected: String) {
        #expect(Sampler.documentPath(fromAXDocument: axDocument) == expected)
    }
}

struct AppIdentityTests {
    @Test func bundleIDWins() {
        #expect(AppIdentity(bundleID: "com.apple.TextEdit", executablePath: "/x/TextEdit") == AppIdentity(type: .bundleID, identifier: "com.apple.TextEdit"))
    }

    @Test func executablePathWithoutBundleID() {
        let expected = AppIdentity(type: .executablePath, identifier: "/usr/local/bin/tool")
        #expect(AppIdentity(bundleID: nil, executablePath: "/usr/local/bin/tool") == expected)
        #expect(AppIdentity(bundleID: "", executablePath: "/usr/local/bin/tool") == expected)
    }

    @Test func neither() {
        #expect(AppIdentity(bundleID: nil, executablePath: nil) == nil)
        #expect(AppIdentity(bundleID: "", executablePath: "") == nil)
        #expect(Snapshot(isScreenLocked: true).app == nil)
    }

    @Test func rawValuesMatchTheSchema() {
        #expect(AppIdentifierType.bundleID.rawValue == 0)
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
        #expect(command("--dump-ax", "com.google.Chrome", "/tmp/chrome.json") == .dumpAX(bundleID: "com.google.Chrome", outputPath: "/tmp/chrome.json"))
        // Arguments macOS or Xcode add are ignored.
        #expect(command("-NSDocumentRevisionsDebugMode", "YES") == .track)
        #expect(TrackerMain.command(arguments: []) == .track)
    }

    @Test func dumpAXWithTheWrongArgumentsIsAnError() {
        #expect(command("--dump-ax") == .usageError)
        #expect(command("--dump-ax", "com.google.Chrome") == .usageError)
        #expect(command("--dump-ax", "com.google.Chrome", "/tmp/a.json", "extra") == .usageError)
    }
}
