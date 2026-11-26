import Foundation
import Testing
@testable import TrackerCore

/// Strings reach the database exactly as macOS reported them, byte for byte. Swift's `==` can't
/// check that: it treats canonically equivalent strings as equal, so these compare `hex()`.
struct StorageTests {
    /// "Café.txt", precomposed (NFC, as typed) and decomposed (NFD, as in many file names).
    private let nfc = "Caf\u{E9}.txt"
    private let nfd = "Cafe\u{301}.txt"

    private func hex(_ s: String) -> String {
        s.utf8.map { String(format: "%02X", $0) }.joined()
    }

    @Test func canonicallyEquivalentTitlesAreStoredAsReported() throws {
        #expect(nfc == nfd, "the premise: Swift considers them equal")
        let h = try RecorderHarness()
        let base = Snapshot(bundleId: "com.apple.TextEdit", appName: "TextEdit", bundlePath: "/System/Applications/TextEdit.app")
        var a = base
        a.windowTitle = nfc
        var b = base
        b.windowTitle = "Other"
        var c = base
        c.windowTitle = nfd
        try h.record(a, at: 0)
        try h.record(b, at: 5_000)
        try h.record(c, at: 10_000)
        try h.record(c, at: 15_000)
        try h.close()
        let rows = try h.temp.db.query("""
            SELECT i.start_ms - ?1, i.end_ms - ?1, hex(t.title)
            FROM tracker_interval i JOIN tracker_title t ON t.id = i.title_id
            ORDER BY i.start_ms
            """, [.int(t0)])
        #expect(rows == [
            [.int(0), .int(5_000), .text("436166C3A92E747874")],
            [.int(5_000), .int(10_000), .text(hex("Other"))],
            [.int(10_000), .int(15_000), .text("43616665CC812E747874")],
        ])
        #expect(try h.temp.count("tracker_title") == 3)
    }

    @Test func lookupTellsCanonicallyEquivalentStringsApart() throws {
        let temp = try TempDatabase()
        let titles = try Lookup(db: temp.db, table: "tracker_title", column: "title")
        let nfcId = try #require(try titles.id(for: nfc))
        let nfdId = try #require(try titles.id(for: nfd))
        #expect(nfcId != nfdId)
        // Cached now, and the same again from a fresh cache (as after a restart).
        #expect(try titles.id(for: nfc) == nfcId)
        #expect(try titles.id(for: nfd) == nfdId)
        let fresh = try Lookup(db: temp.db, table: "tracker_title", column: "title")
        #expect(try fresh.id(for: nfd) == nfdId)
        #expect(try fresh.id(for: nfc) == nfcId)
        #expect(try temp.db.query("SELECT id, hex(title) FROM tracker_title ORDER BY id") == [
            [.int(nfcId), .text(hex(nfc))],
            [.int(nfdId), .text(hex(nfd))],
        ])
    }

    @Test func textWithANulIsStoredAndReadWhole() throws {
        let temp = try TempDatabase()
        let titles = try Lookup(db: temp.db, table: "tracker_title", column: "title")
        let withNul = "a\u{0}b"
        let withNulId = try #require(try titles.id(for: withNul))
        let aId = try #require(try titles.id(for: "a"))
        #expect(withNulId != aId)
        #expect(try temp.db.query("SELECT hex(title), length(CAST(title AS BLOB)) FROM tracker_title WHERE id = ?", [.int(withNulId)]) == [
            [.text("610062"), .int(3)],
        ])
        let read = try temp.db.query("SELECT title FROM tracker_title ORDER BY id")
        let readBytes: [[UInt8]?] = read.map { row in row[0].text.map { Array($0.utf8) } }
        #expect(readBytes == [Array(withNul.utf8), Array("a".utf8)])
    }

    @Test func appNameIsUpdatedToTheReportedBytes() throws {
        let temp = try TempDatabase()
        let apps = try AppLookup(db: temp.db)
        var s = Snapshot(bundleId: "com.example.cafe", appName: nfc, bundlePath: "/Applications/Cafe.app")
        let id = try #require(try apps.id(for: s))
        s.appName = nfd
        #expect(try apps.id(for: s) == id)
        #expect(try temp.db.query("SELECT hex(name) FROM tracker_app") == [[.text(hex(nfd))]])
        s.appName = nfc
        #expect(try apps.id(for: s) == id)
        #expect(try temp.db.query("SELECT hex(name) FROM tracker_app") == [[.text(hex(nfc))]])
    }
}
