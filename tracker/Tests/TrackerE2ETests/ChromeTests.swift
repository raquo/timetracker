import Testing

extension EndToEndTests {
    @Test func chrome() async throws {
        try await Self.run(skipUnless: { $0.chrome != nil }, "no Chrome given (TIMETRACKER_E2E_CHROME)", steps: Self.chromeSteps)
    }

    /// Chrome reports the shown tab's URL as the window's document too, so `document` is the
    /// page URL, scrubbed the same way (docs/url-scrubbing.md).
    private static func chromeSteps(_ run: E2E.Run) async throws {
        guard let chrome = run.chrome, let web = run.served else {
            throw E2EError("no Chrome")
        }
        let r = run.id
        func shows(_ title: String, _ url: String) -> E2E.Expected {
            E2E.Expected(app: chrome.app, window: title + E2E.Chrome.windowSuffix, url: url, page: title, document: url)
        }

        var first: E2E.Chrome.Tab!
        try await run.step("Chrome", expect: shows("One \(r)", web.one)) {
            first = try await chrome.launch(web.one)
            try await chrome.expectFocus(first)
        }
        try await run.step("Chrome: navigate", expect: shows("Two \(r)", web.two)) {
            try await chrome.navigate(first, web.two)
        }
        // Chrome renames the window after the tab, which the tracker hears (`AXTitleChanged`).
        try await run.step("Chrome: page renames itself", expect: shows("Two renamed \(r)", web.two)) {
            try await chrome.eval(first, "document.title = \(E2E.jsString("Two renamed \(r)"))")
            try await chrome.waitUntil(first, "document.title === \(E2E.jsString("Two renamed \(r)"))", "the title didn't change")
        }
        // A new URL without a load, with a secret: scrubbed in the page URL and the document. With
        // a title change, which is what triggers the sample: Chrome sends nothing for `pushState`
        // alone (and updates the page's URL only with the next change), so that would wait for the
        // 5 s poll (docs/page-reading.md#limitations).
        try await run.step("Chrome: pushState and title", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await chrome.eval(first, "history.pushState(null, '', \(E2E.jsString(E2E.Pages.pushedPath))); document.title = \(E2E.jsString("Pushed \(r)"))")
            try await chrome.waitUntil(first, "location.href === \(E2E.jsString(web.pushed))", "pushState didn't change the URL")
        }
        // The fragment isn't recorded, so nothing changes.
        try await run.step("Chrome: hash change", expect: shows("Pushed \(r)", web.pushedScrubbed)) {
            try await chrome.eval(first, "location.hash = 'part'")
            try await chrome.waitUntil(first, "location.hash === '#part'", "the hash didn't change")
            run.sampleNow()
        }
        try await run.step("Chrome: secret in URL", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.navigate(first, web.secret)
        }
        var second: E2E.Chrome.Tab!
        try await run.step("Chrome: new tab", expect: shows("Three \(r)", web.three)) {
            second = try await chrome.open(web.three)
            try await chrome.expectFocus(second)
        }
        try await run.step("Chrome: first tab", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.activate(first)
            try await chrome.expectFocus(first)
            try await chrome.waitUntil(second, "document.visibilityState === 'hidden'", "the second tab is still shown")
        }
        var window: E2E.Chrome.Tab!
        try await run.step("Chrome: new window", expect: shows("One \(r)", web.one)) {
            window = try await chrome.open(web.one, isNewWindow: true)
            try await chrome.expectFocus(window)
        }
        try await run.step("Chrome: window closed", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.close(window)
            try await chrome.expectFocus(first)
        }
        // DevTools docked: two pages side by side in the tab's window, the one holding focus is
        // recorded. The window keeps the tab's title and document. Its URL is read once it has
        // loaded; nothing in it to scrub.
        var devTools: E2E.Chrome.Tab!
        var devToolsUrl = ""
        func showsDevTools() -> E2E.Expected {
            E2E.Expected(app: chrome.app, window: "Secret \(r)" + E2E.Chrome.windowSuffix, url: devToolsUrl, page: "DevTools", document: web.secretScrubbed)
        }
        try await run.step("Chrome: DevTools docked", expect: showsDevTools()) {
            devTools = try await chrome.openDevTools(first)
            devToolsUrl = try await chrome.eval(devTools, "location.href") as? String ?? ""
            try await chrome.expectFocus(devTools)
        }
        // Two content pages and focus in neither: no page is recorded (`PageSearch.choose`). The
        // DevTools Protocol can't move focus out of the pages, so the helper sets it on the
        // address bar through Accessibility.
        try await run.step(
            "Chrome: DevTools docked, focus in address bar",
            expect: E2E.Expected(app: chrome.app, window: "Secret \(r)" + E2E.Chrome.windowSuffix, url: nil, page: nil, document: web.secretScrubbed)
        ) {
            try await run.helper.focusAddressBar(pid: chrome.pid)
            try await chrome.expectNoFocus(first)
            try await chrome.expectNoFocus(devTools)
        }
        // Out of the address bar, the helper moves focus too: `Page.bringToFront` leaves it there.
        // DevTools gets it back through `Page.bringToFront`, not the helper: closed after the
        // helper had focused it, DevTools left focus outside the tab.
        try await run.step("Chrome: DevTools docked, focus in page", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.bringToFront(first)
            try await run.helper.focusPage(pid: chrome.pid, url: try await chrome.eval(first, "location.href") as? String ?? "")
            try await chrome.expectFocus(first)
        }
        try await run.step("Chrome: DevTools docked, focus in DevTools", expect: showsDevTools()) {
            try await chrome.bringToFront(devTools)
            try await chrome.expectFocus(devTools)
        }
        try await run.step("Chrome: DevTools closed", expect: shows("Secret \(r)", web.secretScrubbed)) {
            try await chrome.close(devTools)
            try await chrome.expectFocus(first)
        }
        // Browsers' own pages are content too (docs/page-reading.md).
        try await run.step("Chrome: own page", expect: shows("About Version", "chrome://version/")) {
            try await chrome.navigate(first, "chrome://version/")
        }
        try await run.step("Chrome: other app", expect: .init(run.b, window: "Bee \(r)", url: run.pages.bee, page: "Bee page \(r)")) {
            try await run.activate(run.b)
        }
        try await run.step("Chrome: back", expect: shows("About Version", "chrome://version/")) {
            try await chrome.bringToFront(first)
            try await chrome.expectFocus(first)
        }
    }
}
