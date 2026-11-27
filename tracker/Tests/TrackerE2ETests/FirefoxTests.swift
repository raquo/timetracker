import Testing
@testable import TrackerCore

extension EndToEndTests {
    @Test func firefox() async throws {
        try await Self.run(skipUnless: { $0.firefox != nil }, "no Firefox given (TIMETRACKER_E2E_FIREFOX)", steps: Self.firefoxSteps)
    }

    /// Like Chrome's, with what's different in Firefox: the window is titled with the page title
    /// alone and has no document; a URL change alone (`pushState`) updates the page's URL at
    /// once but sends no event the tracker listens for (only the address bar's
    /// `AXValueChanged`), so it's sampled on request; its own pages (`about:…`) can't be
    /// loaded through BiDi, so they aren't stepped through.
    private static func firefoxSteps(_ run: E2E.Run) async throws {
        guard let firefox = run.firefox, let web = run.served else {
            throw E2EError("no Firefox")
        }
        let r = run.id
        func shows(_ title: String, _ url: String) -> E2E.Expected {
            E2E.Expected(app: firefox.app, window: title + E2E.Firefox.windowSuffix, url: url, page: title, document: nil)
        }

        // Firefox builds its page tree only once something asks for it, so the tracker's first
        // probe, when Firefox comes to the front, may find no page. The retry 2 s later
        // (`PageReadingPolicy.probeBackoff`) finds it; until then only the window is recorded.
        var first: E2E.Firefox.Tab!
        try await run.step(
            "Firefox",
            expect: shows("One \(r)", web.one),
            mayFirstBe: E2E.Expected(app: firefox.app, window: "One \(r)" + E2E.Firefox.windowSuffix, url: nil, page: nil, document: nil),
            extraLatencyMs: PageReadingPolicy.probeBackoff.firstDelayMs
        ) {
            first = try await firefox.launch(web.one)
            try await firefox.expectFocus(first)
        }
        try await run.step("Firefox: navigate", expect: shows("Two \(r)", web.two)) {
            try await firefox.navigate(first, web.two)
        }
        // Firefox renames the window after the tab, which the tracker hears (`AXTitleChanged`).
        try await run.step("Firefox: page renames itself", expect: shows("Two renamed \(r)", web.two)) {
            try await firefox.eval(first, "document.title = \(E2E.jsString("Two renamed \(r)"))")
            try await firefox.waitUntil(first, "document.title === \(E2E.jsString("Two renamed \(r)"))", "the title didn't change")
        }
        // No event: sampled on request.
        try await run.step("Firefox: pushState alone", expect: shows("Two renamed \(r)", web.moved)) {
            try await firefox.eval(first, "history.pushState(null, '', \(E2E.jsString(E2E.Pages.movedPath)))")
            try await firefox.waitUntil(first, "location.href === \(E2E.jsString(web.moved))", "pushState didn't change the URL")
            run.sampleNow()
        }
        // With a secret, scrubbed; the title change triggers the sample.
        try await run.step("Firefox: pushState and title", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await firefox.eval(first, "history.pushState(null, '', \(E2E.jsString(E2E.Pages.pushedPath))); document.title = \(E2E.jsString("Pushed \(r)"))")
            try await firefox.waitUntil(first, "location.href === \(E2E.jsString(web.pushed))", "pushState didn't change the URL")
        }
        // The fragment isn't recorded, so nothing changes.
        try await run.step("Firefox: hash change", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await firefox.eval(first, "location.hash = 'part'")
            try await firefox.waitUntil(first, "location.hash === '#part'", "the hash didn't change")
            run.sampleNow()
        }
        try await run.step("Firefox: secret in URL", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.navigate(first, web.secret)
        }
        var second: E2E.Firefox.Tab!
        try await run.step("Firefox: new tab", expect: shows("Three \(r)", web.three)) {
            second = try await firefox.open(web.three)
            try await firefox.expectFocus(second)
        }
        try await run.step("Firefox: first tab", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.activate(first)
            try await firefox.expectFocus(first)
            try await firefox.waitUntil(second, "document.visibilityState === 'hidden'", "the second tab is still shown")
        }
        var window: E2E.Firefox.Tab!
        try await run.step("Firefox: new window", expect: shows("One \(r)", web.one)) {
            window = try await firefox.open(web.one, isNewWindow: true)
            try await firefox.expectFocus(window)
        }
        try await run.step("Firefox: window closed", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.close(window)
            try await firefox.expectFocus(first)
        }
        try await run.step("Firefox: other app", expect: .init(run.b, window: "Bee \(r)", url: run.pages.bee, page: "Bee page \(r)")) {
            try await run.activate(run.b)
        }
        try await run.step("Firefox: back", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await firefox.bringToFront()
            try await firefox.expectFocus(first)
        }
    }
}
