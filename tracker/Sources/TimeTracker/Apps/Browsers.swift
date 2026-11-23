/// Web browsers whose page URL the tracker reads from the Accessibility tree, like it does for
/// Electron apps, but without switching anything on: they expose the shown tab's `AXWebArea`
/// (with `AXURL`) to any Accessibility client. Verified on 2026-11-22 with Firefox Developer
/// Edition, Safari and Chrome. Only the shown tab's page is in the tree, so there's no need to
/// tell tabs apart.
///
/// The first read after a browser starts can come back empty while it builds the tree.
enum Browsers {
    static let bundleIDs: Set<String> = [
        // Firefox
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        // Safari
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        // Chromium family
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]
}
