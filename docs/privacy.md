# Privacy

What the app does to protect the user's privacy: what it never records, what it removes before recording, and where recorded data goes. This doc is the overview; each measure lives in its own doc, linked below. The tracker records what's on screen all day, so this is a concern for every feature, not one feature of its own.

## What the tracker never records

- **Keystrokes and typed text.** No keyboard monitor or event tap, ever. Input is used only as "time since the last input" (for idle) and "a click happened" (as a trigger to sample), never where or on what. [tracker-principles.md](tracker-principles.md#no-keylogging-ever).
- **What's on a page.** From an app's web content the tracker reads only the page's URL and title, never its text, form fields or anything else in it ([page-reading.md](page-reading.md)).

## What it removes before recording

**Privacy is enforced in the tracker, before writing.** Anything that must not be stored is removed before it reaches the database, since a later cleanup can't un-write the file: deleted rows linger in the WAL, free pages and backups. [tracker-principles.md](tracker-principles.md#privacy-is-enforced-in-the-tracker-before-writing).

- **URL scrubbing:** every recorded URL loses its fragment, and secrets and personal data in it (tokens, passwords, email addresses) are replaced with `REDACTED`. This covers page URLs and web addresses that apps report as the window's document. A URL that can't be scrubbed isn't recorded. [url-scrubbing.md](url-scrubbing.md).

## Where the data goes

- **It stays on the Mac.** The tracker writes only to a local SQLite database and has no network code. The server, once built, serves the UI on `127.0.0.1` only, behind a token ([architecture.md](architecture.md#server-security)).
- **The server can't read the screen.** Only the tracker has Accessibility permission; the server is a separate signed app without it ([architecture.md](architecture.md#isolation)).

## Diagnostics and test data

The dump tool and test fixtures read apps' trees outside normal tracking. Fixtures are committed to the repository, so they save only roles and the few attributes the tracker reads, and should be recorded on neutral pages. Text dumps hold page content and aren't meant to be shared unread. [diagnostics.md](diagnostics.md).

## Not built yet

Planned, in [PLAN.md](../notes/PLAN.md) ("Tracker: privacy"):

- **Exclusions:** no tracking for chosen apps, domains, title patterns, and private browser windows; plus pause.
- **Per-site scrubbing exceptions:** letting a parameter through where it names a document, not a secret.
- **Deleting tracked data,** including the lookup rows it leaves behind.
- **Sensitive data the UI doesn't show:** deciding whether the app may keep data the user can't see, and so can't find or delete.

Exclusions and scrubbing exceptions will be settings the user edits in the UI, kept in server tables that the tracker reads and applies before writing ([architecture.md](architecture.md#settings-that-change-tracking)).

## Limitations

- **Titles aren't scrubbed.** Window and page titles are recorded as reported, and can carry email subjects, document names and chat snippets.
- **Nothing is excluded yet.** Private and incognito windows, password managers and banking apps are recorded like any other app (scrubbed URLs, raw titles). Page reading makes this matter more: probing reads pages in apps that used to have only window titles recorded ([page-reading.md](page-reading.md#limitations)).
- **Recorded data can't be deleted from the app yet.**
- **URL scrubbing has gaps of its own:** [url-scrubbing.md](url-scrubbing.md#limitations).
