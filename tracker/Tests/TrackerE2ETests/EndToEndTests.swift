import Testing

/// The real tracker (the build copy, which holds the Accessibility permission) records into a
/// temporary database, with its poll turned off, while each test drives what it's named after:
/// three copies of `E2ETarget`, a throwaway Google Chrome, or a throwaway Firefox; then the rows
/// are checked against what each step showed. Each test has a run of its own (`E2E.Run`). See
/// docs/end-to-end-tests.md.
///
/// Run by scripts/e2e.sh, which builds the apps, makes the run folder, and cleans up after a
/// crash. Skipped otherwise. Environment:
/// - `TIMETRACKER_E2E_TRACKER`: the tracker app to run;
/// - `TIMETRACKER_E2E_APPS`: folder holding the three target apps;
/// - `TIMETRACKER_E2E_HELPER`: the helper app (`E2E.Helper`);
/// - `TIMETRACKER_E2E_RUN`: a folder for this run, where each test makes a folder named after
///   itself and leaves `checked` in it (`E2E.Run.noteChecked`);
/// - `TIMETRACKER_E2E_CHROME`, `TIMETRACKER_E2E_FIREFOX`: the browser apps to drive. Empty: that
///   browser's test is skipped. Not set: every test fails.
///
/// One suite, with each test in an extension in a file of its own (`ChromeTests.swift`, …): Swift
/// Testing runs suites in parallel, and two tests at once would fight over the front app.
@Suite(.serialized, .enabled(if: E2E.isEnabled, "run by scripts/e2e.sh"))
struct EndToEndTests {
    /// Starts a run, does its `steps`, checks its rows. Unless `isGiven` says what the test drives
    /// wasn't given: then the test skips itself before anything starts, saying `reason` in
    /// `checked`.
    static func run(
        skipUnless isGiven: (E2E.Run) -> Bool = { _ in true },
        _ reason: String = "",
        steps: (E2E.Run) async throws -> Void
    ) async throws {
        let run = try E2E.Run()
        guard isGiven(run) else {
            print("e2e: \(reason), skipped")
            try run.noteChecked("skipped: \(reason)")
            return
        }
        try await run.perform {
            try await steps(run)
        }
        try run.check()
    }
}
