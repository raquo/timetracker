/// The Claude desktop app (Electron).
///
/// Its window title is always "Claude", so the tracker reads the conversation from its web content:
/// the focused window holds Claude's own UI (`file://…/app.asar/…`) and one `https://claude.ai/…`
/// page, whose URL identifies the conversation and whose title is its name. Details:
/// notes/electron-and-claude.md.
///
/// Planned here: reading the session files that map a Code session's URL to its folder and
/// environment (TODO in notes/PLAN.md).
enum Claude {
    static let bundleId = "com.anthropic.claudefordesktop"
}
