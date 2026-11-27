# Test fixtures

What fixtures hold and how the replay tests use them: [docs/diagnostics.md](../../../../docs/diagnostics.md).

## `ax/`: recorded Accessibility trees

Each file is an `AxFixture`: an app's focused window, trimmed to what the tracker reads, plus
what the tracker's page search found on it live. `AxReplayTests` replays each one and checks:

- the replay finds the same as the live search did (so the fake elements behave like the real ones);
- the snapshot the tracker would record from it, written by hand per fixture in `AxReplayTests.expected`.

To record one, with the app set up as wanted (it needn't be in front):

    open -n -W ~/Applications/TimeTracker.app --args --dump-ax <bundle-id> <output-file> --json

Must run through `open`, as the installed app (or the build copy), for its Accessibility permission. Name the file
`<app>-<what's shown>.json`, e.g. `chrome-example-page.json`.

Privacy: fixtures hold window titles and page URLs and titles as reported. Record them on
neutral pages, and read each file before adding it.
