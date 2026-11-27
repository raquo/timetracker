import Foundation
import Testing

extension EndToEndTests {
    @Test func targetApps() async throws {
        try await Self.run(steps: Self.targetAppSteps)
    }

    /// Steps that change nothing ask the tracker for a sample (`sampleNow`) before they count:
    /// otherwise they'd pass without the tracker having looked. Proven to work by "page renames
    /// itself", which nothing else would record (the poll is turned off).
    private static func targetAppSteps(_ run: E2E.Run) async throws {
        let r = run.id
        let a = run.a
        let b = run.b
        let c = run.c
        let pages = run.pages

        try await run.step("plain window", expect: .init(a, window: "Plain \(r)")) {
            try await a.send("openWindow", ["id": "plain", "title": "Plain \(r)"])
        }
        try await run.step("web window", expect: .init(a, window: "Web \(r)", url: pages.one, page: "One \(r)")) {
            try await a.send("openWindow", ["id": "web", "title": "Web \(r)", "pages": [pages.one]])
        }
        try await run.step("navigate", expect: .init(a, window: "Web \(r)", url: pages.two, page: "Two \(r)")) {
            try await a.send("navigate", ["id": "web", "url": pages.two])
        }
        // WebKit sends no event for this (docs/page-reading.md#limitations), so only the sample
        // asked for records it.
        try await run.step("page renames itself", expect: .init(a, window: "Web \(r)", url: pages.two, page: "Two retitled \(r)")) {
            try await a.send("eval", ["id": "web", "js": "document.title = \(E2E.jsString("Two retitled \(r)"))"])
            try await a.waitUntil(window: "web", "document.title === \(E2E.jsString("Two retitled \(r)"))", "the title didn't change")
            run.sampleNow()
        }
        // The fragment isn't recorded (docs/url-scrubbing.md), so nothing changes.
        try await run.step("hash change", expect: .init(a, window: "Web \(r)", url: pages.two, page: "Two retitled \(r)")) {
            try await a.send("eval", ["id": "web", "js": "location.hash = 'part'"])
            try await a.waitUntil(window: "web", "location.hash === '#part'", "the hash didn't change")
            run.sampleNow()
        }
        try await run.step(
            "secret in URL",
            expect: .init(a, window: "Web \(r)", url: pages.secretScrubbed, page: "Secret \(r)")
        ) {
            try await a.send("navigate", ["id": "web", "url": pages.secret])
        }
        try await run.step(
            "window renamed",
            expect: .init(a, window: "Web renamed \(r)", url: pages.secretScrubbed, page: "Secret \(r)")
        ) {
            try await a.send("setTitle", ["id": "web", "title": "Web renamed \(r)"])
        }
        try await run.step("other window", expect: .init(a, window: "Plain \(r)")) {
            try await a.send("focusWindow", ["id": "plain"])
        }
        try await run.step("other app", expect: .init(b, window: "Bee \(r)", url: pages.bee, page: "Bee page \(r)")) {
            try await run.activate(b)
        }
        try await run.step("back", expect: .init(a, window: "Plain \(r)")) {
            try await run.activate(a)
        }
        // Two pages and focus in neither: no page is recorded (can't tell which one is being read).
        try await run.step("split, no focus", expect: .init(a, window: "Split \(r)")) {
            try await a.send("openWindow", ["id": "split", "title": "Split \(r)", "pages": [pages.one, pages.two], "isFocusCleared": true])
            try await a.expectFocus(window: "split", inPage: nil, of: 2)
        }
        try await run.step("split, focus right", expect: .init(a, window: "Split \(r)", url: pages.two, page: "Two \(r)")) {
            try await a.send("focusPage", ["id": "split", "index": 1])
            try await a.expectFocus(window: "split", inPage: 1, of: 2)
        }
        try await run.step("split, focus left", expect: .init(a, window: "Split \(r)", url: pages.one, page: "One \(r)")) {
            try await a.send("focusPage", ["id": "split", "index": 0])
            try await a.expectFocus(window: "split", inPage: 0, of: 2)
        }
        try await run.step("page with iframe", expect: .init(a, window: "Frame \(r)", url: pages.frame, page: "Frame \(r)")) {
            try await a.send("openWindow", ["id": "frame", "title": "Frame \(r)", "pages": [pages.frame]])
        }
        // The iframe is part of the page: still the outer page.
        try await run.step("focus in iframe", expect: .init(a, window: "Frame \(r)", url: pages.frame, page: "Frame \(r)")) {
            try await a.send("focusPage", ["id": "frame"])
            try await a.send("eval", ["id": "frame", "js": "document.querySelector('iframe').contentDocument.getElementById('i').focus()"])
            try await a.waitUntil(
                window: "frame",
                "document.querySelector('iframe').contentDocument.activeElement?.id === 'i' && document.hasFocus()",
                "focus didn't reach the iframe's text field"
            )
            run.sampleNow()
        }
        // A page titled "Loading" that renames itself 450 ms after loading, between the tracker's
        // first look (300 ms after the load event) and its second (400 ms later). Settling must
        // hide the "Loading" state: the row is the final page, starting when the change was first
        // seen, so before the rename (`Settler`).
        try await run.step("page settles after loading", expect: .init(a, window: "Frame \(r)", url: pages.settle, page: "Loaded \(r)")) {
            try await a.send("navigate", ["id": "frame", "url": pages.settle])
            try await a.waitUntil(window: "frame", "document.title === \(E2E.jsString("Loaded \(r)"))", "the page didn't rename itself")
            guard let renamedAtMs = try await a.send("eval", ["id": "frame", "js": "window.renamedAtMs"]) as? NSNumber else {
                throw E2EError("the page didn't say when it renamed itself")
            }
            run.expectRowStart(before: renamedAtMs.int64Value)
        }
        try await run.step("plain window again", expect: .init(a, window: "Plain \(r)")) {
            try await a.send("focusWindow", ["id": "plain"])
        }
        // An app whose only page is its own UI, loaded from its bundle: not content, so no page
        // is recorded, and page reading stays undecided (checked in `Run.check`).
        try await run.step("own UI only", expect: .init(c, window: "Own \(r)")) {
            try await c.send("openWindow", ["id": "own", "title": "Own \(r)", "pages": [c.ownPage]])
            try await run.activate(c)
        }
        try await run.step("panel", expect: .init(c, window: "Panel \(r)", subrole: "AXFloatingWindow", isMainWindow: false)) {
            try await c.send("openWindow", ["id": "panel", "title": "Panel \(r)", "isPanel": true])
        }
        try await run.step("no window", expect: .noWindow(c)) {
            try await c.send("closeWindow", ["id": "panel"])
            try await c.send("closeWindow", ["id": "own"])
        }
    }
}
