import Foundation
import Testing
@testable import TrackerCore

struct HolderJsonTests {
    @Test func emptyIsAnEmptyArray() {
        #expect(HolderEntry.json([]) == "[]")
    }

    @Test func absentKeysAreLeftOut() {
        #expect(HolderEntry.json([HolderEntry(app: 12, rsn: nil, via: nil)]) == #"[{"app":12}]"#)
        #expect(HolderEntry.json([HolderEntry(app: nil, rsn: "x", via: nil)]) == #"[{"rsn":"x"}]"#)
        #expect(HolderEntry.json([HolderEntry(app: 7, rsn: "caffeinate command-line tool", via: 31)])
            == #"[{"app":7,"rsn":"caffeinate command-line tool","via":31}]"#)
    }

    @Test func isCanonicalWhateverTheOrder() {
        let entries = [
            HolderEntry(app: 40, rsn: "Amphetamine (Single-Use - Display)", via: nil),
            HolderEntry(app: 12, rsn: "Video Wake Lock", via: nil),
            HolderEntry(app: 12, rsn: "Blink Wake Lock", via: nil),
            HolderEntry(app: nil, rsn: "gone", via: nil),
            HolderEntry(app: 12, rsn: nil, via: nil),
            HolderEntry(app: 7, rsn: "c", via: 31),
            HolderEntry(app: 7, rsn: "c", via: 30),
        ]
        let expected = #"[{"rsn":"gone"},{"app":7,"rsn":"c","via":30},{"app":7,"rsn":"c","via":31},{"app":12},{"app":12,"rsn":"Blink Wake Lock"},{"app":12,"rsn":"Video Wake Lock"},{"app":40,"rsn":"Amphetamine (Single-Use - Display)"}]"#
        #expect(HolderEntry.json(entries) == expected)
        #expect(HolderEntry.json(entries.reversed()) == expected)
    }

    @Test func duplicatesAreDropped() {
        let entry = HolderEntry(app: 12, rsn: "Video Wake Lock", via: nil)
        #expect(HolderEntry.json([entry, entry]) == #"[{"app":12,"rsn":"Video Wake Lock"}]"#)
    }

    @Test func namesAreComparedByteForByte() {
        // "é" precomposed and decomposed: Swift's == calls them equal, the stored JSON doesn't.
        let json = HolderEntry.json([HolderEntry(app: 1, rsn: "caf\u{E9}", via: nil), HolderEntry(app: 1, rsn: "cafe\u{301}", via: nil)])
        #expect(json == "[{\"app\":1,\"rsn\":\"cafe\u{301}\"},{\"app\":1,\"rsn\":\"caf\u{E9}\"}]")
    }

    @Test func namesAreEscaped() {
        #expect(HolderEntry.json([HolderEntry(app: 1, rsn: "a \"b\" \\ c/d\n", via: nil)]) == #"[{"app":1,"rsn":"a \"b\" \\ c/d\n"}]"#)
    }
}

struct DisplaySleepHolderTests {
    private static func app(_ name: String) -> ProcessApp {
        ProcessApp(identity: AppIdentity(type: .bundleId, identifier: "test.\(name)"), appPath: "/Applications/\(name).app", name: name)
    }

    private static let apps: [pid_t: ProcessApp] = [
        100: app("Amphetamine"), 200: app("Chrome"), 300: app("caffeinate"), 400: app("Terminal"), 500: app("Claude"),
    ]

    private static func assertion(_ type: String, _ name: String, trueType: String? = nil, level: Int = 255, onBehalfOf: pid_t? = nil) -> [String: Any] {
        var a: [String: Any] = ["AssertType": type, "AssertName": name, "AssertLevel": NSNumber(value: level)]
        a["AssertionTrueType"] = trueType
        a["AssertionOnBehalfOfPID"] = onBehalfOf.map { NSNumber(value: $0) }
        return a
    }

    private func holders(_ assertions: [pid_t: [[String: Any]]]) -> Set<SignalHolder> {
        PresenceReader.displaySleepHolders(from: assertions) { Self.apps[$0] }
    }

    /// As `IOPMCopyAssertionsByProcess` reported them on macOS 15.6.
    @Test func keepsOnlyDisplaySleepAssertionsThatAreOn() {
        let found = holders([
            100: [
                Self.assertion("PreventUserIdleSystemSleep", "Amphetamine (Single-Use - System)", trueType: "PreventUserIdleSystemSleep"),
                Self.assertion("PreventUserIdleDisplaySleep", "Amphetamine (Single-Use - Display)", trueType: "PreventUserIdleDisplaySleep"),
            ],
            200: [
                Self.assertion("PreventUserIdleDisplaySleep", "Video Wake Lock", level: 0),
                // Legacy type, mapped to the current one.
                Self.assertion("NoDisplaySleepAssertion", "Old API", trueType: "PreventUserIdleDisplaySleep"),
            ],
            // Electron's: a system sleep assertion under a legacy name.
            500: [Self.assertion("NoIdleSleepAssertion", "Electron", trueType: "PreventUserIdleSystemSleep")],
        ])
        #expect(found == [
            SignalHolder(app: Self.apps[100], reason: "Amphetamine (Single-Use - Display)"),
            SignalHolder(app: Self.apps[200], reason: "Old API"),
        ])
    }

    @Test func aProxyIsRecordedAsVia() {
        let found = holders([
            300: [
                Self.assertion("PreventUserIdleDisplaySleep", "caffeinate command-line tool", onBehalfOf: 400),
                // On behalf of itself: no proxy.
                Self.assertion("PreventUserIdleDisplaySleep", "self", onBehalfOf: 300),
                // On behalf of a process that's gone.
                Self.assertion("PreventUserIdleDisplaySleep", "orphan", onBehalfOf: 999),
            ],
        ])
        #expect(found == [
            SignalHolder(app: Self.apps[400], via: Self.apps[300], reason: "caffeinate command-line tool"),
            SignalHolder(app: Self.apps[300], reason: "self"),
            SignalHolder(app: nil, via: Self.apps[300], reason: "orphan"),
        ])
    }

    @Test func withoutATrueTypeTheTypeCounts() {
        let found = holders([
            200: [
                Self.assertion("NoDisplaySleepAssertion", "legacy"),
                Self.assertion("PreventUserIdleDisplaySleep", "current"),
                Self.assertion("PreventUserIdleSystemSleep", "system"),
            ],
        ])
        #expect(found == [SignalHolder(app: Self.apps[200], reason: "legacy"), SignalHolder(app: Self.apps[200], reason: "current")])
    }

    @Test func noAssertionsNoHolders() {
        #expect(holders([:]).isEmpty)
    }
}

struct ProcessAppTests {
    @Test func aGoneProcessIsNil() {
        #expect(ProcessApp(pid: 99_999_999) == nil)
    }

    @Test func aProcessWithoutABundleIsItsExecutable() throws {
        // launchd: no app bundle.
        let app = try #require(ProcessApp(pid: 1))
        #expect(app.identity == AppIdentity(type: .executablePath, identifier: "/sbin/launchd"))
        #expect(app.appPath == "/sbin/launchd")
    }
}

struct PresenceRecordingTests {
    private let temp: TempDatabase
    private let h: RecorderHarness

    init() throws {
        temp = try TempDatabase()
        h = try RecorderHarness(temp: temp)
    }

    private static let amphetamine = ProcessApp(
        identity: AppIdentity(type: .bundleId, identifier: "com.if.Amphetamine"),
        appPath: "/Applications/Amphetamine.app",
        name: "Amphetamine"
    )
    private static let caffeinate = ProcessApp(
        identity: AppIdentity(type: .executablePath, identifier: "/usr/bin/caffeinate"),
        appPath: "/usr/bin/caffeinate",
        name: nil
    )

    private func withPresence(_ s: Snapshot, _ presence: PresenceSignals) -> Snapshot {
        var s = s
        s.presence = presence
        return s
    }

    private func appId(_ identifier: String) throws -> Int64 {
        try #require(temp.db.query("SELECT id FROM tracker_app WHERE identifier = ?", [.text(identifier)]).first?[0].int)
    }

    @Test func storesSignalsAndHoldersAsAppIds() throws {
        let presence = PresenceSignals(
            displaySleepHolders: [
                SignalHolder(app: Self.amphetamine, reason: "Amphetamine (Single-Use - Display)"),
                SignalHolder(app: Fixtures.youtube.processApp, via: Self.caffeinate, reason: "caffeinate command-line tool"),
            ],
            isCameraInUse: false,
            micHolders: [SignalHolder(app: Fixtures.youtube.processApp)]
        )
        try h.record(withPresence(Fixtures.youtube, presence), at: 0)
        try h.record(withPresence(Fixtures.youtube, presence), at: 1_000)
        try h.close()
        let rows = try h.rows()
        let firefox = try appId("org.mozilla.firefoxdeveloperedition")
        let amphetamine = try appId("com.if.Amphetamine")
        let caffeinate = try appId("/usr/bin/caffeinate")
        #expect(rows.count == 1)
        #expect(rows.first?.isCameraInUse == false)
        let expected = [
            #"{"app":\#(firefox),"rsn":"caffeinate command-line tool","via":\#(caffeinate)}"#,
            #"{"app":\#(amphetamine),"rsn":"Amphetamine (Single-Use - Display)"}"#,
        ]
        #expect(rows.first?.displaySleepHolders == "[" + (firefox < amphetamine ? expected : expected.reversed()).joined(separator: ",") + "]")
        #expect(rows.first?.micHolders == #"[{"app":\#(firefox)}]"#)
        // A holder without a bundle gets its executable's name.
        #expect(try temp.db.query("SELECT identifier_type, app_path, name FROM tracker_app WHERE id = ?", [.int(caffeinate)])
            == [[.int(1), .text("/usr/bin/caffeinate"), .text("caffeinate")]])
    }

    @Test func noneIsAnEmptyListAndNotMeasuredIsNull() throws {
        let none = PresenceSignals(displaySleepHolders: [], isCameraInUse: false, micHolders: [])
        let unknown = PresenceSignals(displaySleepHolders: [], isCameraInUse: nil, micHolders: nil)
        try h.record(withPresence(Fixtures.notes, none), at: 0)
        try h.record(withPresence(Fixtures.notes, unknown), at: 1_000)
        try h.record(withPresence(Fixtures.notes, unknown), at: 2_000)
        try h.close()
        let rows = try h.rows()
        #expect(rows.map(\.displaySleepHolders) == ["[]", "[]"])
        #expect(rows.map(\.micHolders) == ["[]", nil])
        #expect(rows.map(\.isCameraInUse) == [false, nil])
    }

    @Test func aHolderChangeStartsANewRow() throws {
        func holding(_ holders: Set<SignalHolder>) -> Snapshot {
            withPresence(Fixtures.youtube, PresenceSignals(displaySleepHolders: holders))
        }
        let amphetamine = SignalHolder(app: Self.amphetamine, reason: "Amphetamine (Single-Use - Display)")
        let video = SignalHolder(app: Fixtures.youtube.processApp, reason: "Video Wake Lock")
        try h.record(holding([amphetamine]), at: 0)
        try h.record(holding([amphetamine, video]), at: 1_000)
        try h.record(holding([video, amphetamine]), at: 2_000)
        try h.record(holding([]), at: 3_000)
        try h.close()
        #expect(try h.rows().map(\.endMs) == [t0 + 1_000, t0 + 3_000])
    }
}
