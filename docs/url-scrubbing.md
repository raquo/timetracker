# URL scrubbing

Before the tracker records a URL, it drops the fragment and replaces secrets and personal data with `REDACTED`. This doc covers which URLs are scrubbed, the rules, and the exceptions we chose. Privacy as a whole, and how this fits in: [privacy.md](privacy.md). Where URLs come from: [page-reading.md](page-reading.md). The columns that hold them: [data-model.md](data-model.md).

## Behaviour

Every URL the tracker records is scrubbed first: page URLs (`page_url_id`) and web addresses that apps report as the window's document (`document_path_id`). A URL that can't be scrubbed isn't recorded at all. Examples:

| Seen | Recorded |
|---|---|
| `https://app.notion.com/p/Plan-41a8…#9f2c…` | `https://app.notion.com/p/Plan-41a8…` |
| `https://mail.google.com/mail/u/0/#inbox/FMfcgz…` | `https://mail.google.com/mail/u/0/#inbox` |
| `https://us02web.zoom.us/j/812…?pwd=aBcD.1` | `https://us02web.zoom.us/j/812…?pwd=REDACTED` |
| `https://app.example.com/login?email=alice%40example.com&next=%2Fverify%3Ftoken%3Dabc` | `https://app.example.com/login?email=REDACTED&next=%2Fverify%3Ftoken%3DREDACTED` |
| `https://bob:pw@app.example.com/` | `https://REDACTED:REDACTED@app.example.com/` |
| `data:image/png;base64,iVBORw0…` | `data:image/png;base64,REDACTED` |
| `https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s` | unchanged, byte for byte |

Window titles and page titles are recorded as reported: nothing scrubs them ([privacy.md](privacy.md#limitations)).

## How a URL is scrubbed

One function scrubs every URL before it reaches a lookup insert. It either returns the scrubbed URL, or nothing, and then the URL isn't recorded: a URL it can't take apart or put back together is never written unscrubbed. A URL with nothing to remove comes back exactly as given, not normalized (case, encoding, parameter order and `+` all stay), so the same page always gives the same row ([Why](#why)). Code: `UrlScrubber.scrub`; cases: `UrlScrubberTests`.

### Fragments

**The `#…` part of every URL is dropped.** A fragment is usually a position within the page (Notion's `#<block-id>`, heading anchors), which would split one page into many rows without saying anything about what's being worked on. Some carry secrets (`#access_token=…` in OAuth's implicit flow).

**Exception: apps that route by fragment keep its first segment,** if it's a plain word (letters, digits, `-`, `_`). Gmail's `#inbox/<message-id>` becomes `#inbox`: which view is open is worth keeping, and the message is in the title anyway. `#access_token=…` on such a host is still dropped, since it isn't a plain word. The list of hosts: `UrlScrubber.fragmentRoutedHosts`, so far only `mail.google.com`.

### Redaction

A redacted value is replaced with `REDACTED` and its name is kept (`?token=REDACTED`), as logging tools do ([Background](#background)). Empty values stay: there's nothing to hide. Redacted:

- **User name and password** in the address: `https://REDACTED:REDACTED@host/`.
- **Query parameters whose name says they hold a secret:** `code`, `key`, `sig`, `otp`, `nonce`, `pwd`, `ticket`, `jwt`, `sid`, `hash`, …, and any name containing `token`, `secret`, `password`, `signature`, `session`, `sessid`, `api_key`, `access_key`, `private_key`, `x_amz_`, `x_goog_`. Also one-time codes under other names (`oobCode`, `auth_code`, `verification_code`, …), OAuth 1.0a's `oauth_verifier`, and card codes (`cvc`, `cvv`). The full list: `UrlScrubber.redactedNames`.
- **Query parameters whose name says they hold personal data:** `login`, `login_hint`, `user_name`, and any name containing `email`.
- **Any value that contains an email address,** whole or within a search (`q=email+bob%40example.co.uk+invoice`), even percent-encoded twice. Code: `UrlScrubber.isEmailAddress`.
- **Any path segment that contains an email address,** redacted whole: `/u/alice@example.com/profile` → `/u/REDACTED/profile`. Handles without one (`/@alice.smith`, `/@types/node`) stay.
- **Path parameters under those names** (`/cart;jsessionid=…`, Java servers' session ID), and parameters after a `;` inside a query value (`?a=1;token=…`), since some servers split the query on `;` too.
- **URLs carried in a parameter** (`?next=`, `?continue=`, `?redirect_uri=`) are scrubbed by the same rules, up to 3 levels deep, and re-encoded. One with nothing to remove stays byte for byte. One with an email address still left in it (in a parameter name, say) is redacted whole.
- **The content of a `data:` URL** (an image or a page opened from one): it's the page itself. Its media type stays.

**Names match in any spelling.** Before comparing, a name is percent-decoded, lowercased and stripped of everything but letters and digits, so `access_key`, `accessKey`, `ACCESS-KEY` and `access%5Fkey` are all `accesskey`. In form field names (`user[login]`) the innermost key counts too. Code: `LooseNamePattern`.

**Everything else stays,** since much of it says what's open: `?v=` on YouTube, `?q=` in searches, GitHub's `?state=closed`, `?tab=` in Google Docs. Exact names aren't matched as parts, so `keyword`, `codec`, `hashtag` and `author` stay, and so do harmless codes (`country_code`, `promo_code`).

## Window documents (`AXDocument`)

Apps report the window's document as a URL in `AXDocument`, which the tracker stores as `document_path_id` ([data-model.md](data-model.md#intervals-tracker_interval)). Usually it's a file:

- **`file://` URLs** are stored as plain paths, decoded (`/Users/someone/My Notes/café.md`). Nothing is scrubbed from them.
- **Any other URL is scrubbed like a page URL.** Chrome reports the tab's address there (`https://…`, `chrome://…`), so without this the same URL would be stored scrubbed as the page and raw as the document. Not recorded if it can't be scrubbed.
- **A string that isn't a URL** (no scheme) is kept as reported, unless it contains `://`: then it looks like a URL that couldn't be taken apart, and isn't recorded.

Code: `Sampler.documentPath(fromAxDocument:)`; cases: `DocumentPathTests`.

## Decided exceptions

_TODO: These are app-specific, do we need to document them elsewhere?_

Things that look sensitive but are kept on purpose. Each was weighed and is recorded here so it isn't "fixed" by accident.

- **Gmail's view in the fragment** (`mail.google.com`): `#inbox/<message-id>` is recorded as `#inbox`, though fragments are otherwise dropped. Says which view is open; the message ID goes. The only fragment-routed host so far ([Fragments](#fragments)).
- **Google Calendar event IDs** (`?eid=…`, `/eventedit/<id>`). They're base64 of the event ID plus the calendar owner's email address. Kept: not a secret, not readable at a glance, and the event ID says which meeting the time went to. The email check doesn't look inside base64, so it doesn't catch them. Revisit if recorded data is ever shared or exported.
- **OAuth's `state`:** a one-time nonce, not a secret, and GitHub uses the same name for views (`/issues?state=closed`).
- **Document IDs in the path** (Google Docs `/document/d/<id>/edit`, Notion page IDs). They say which document the time went to, and shared documents have their own access control.
- **Tracking parameters** (`utm_*`, `fbclid`, `gclid`): not secret. They split one page into several URLs, so removing them is still an open idea in [PLAN.md](../notes/PLAN.md) ("Strip tracking parameters").

## Why

- **Scrubbed in the tracker, before writing,** not cleaned up later ([tracker-principles.md](tracker-principles.md#privacy-is-enforced-in-the-tracker-before-writing)).
- **Redact the value, keep the name.** The URL keeps its shape and still says a secret was there (a sign-in or password reset link), in line with recording raw data generously. Rejected: dropping the parameter, which hides that anything was there; dropping the whole URL, which loses the page.
- **A denylist of names, not an allowlist.** Most parameters say what's open (`?v=`, `?q=`, `?tab=`), and an allowlist would need every site's parameters listed. The price: a secret under an innocent name gets through (see [Limitations](#limitations)).
- **Names matched loosely.** Missing one spelling of a secret name leaks it; an extra match only redacts a harmless value (`max_tokens`).
- **Not recorded rather than recorded unscrubbed** when a URL can't be taken apart. Losing a page is better than storing a secret.
- **Left byte for byte when nothing changes,** rather than normalized: what's recorded is what the app showed, and only what had to go is changed.
- **Fragments dropped by default, kept by host.** A fragment is almost always a position or a secret; the few apps that route by it are listed by hand.
- **`AXDocument` URLs scrubbed like page URLs.** Otherwise Chrome's tab URL would reach the database unscrubbed through the document column.

## Background

- **Chrome reports the shown tab's URL as the window's document** (`AXDocument`), including its own pages (`chrome://settings/…`). Observed in Chrome; Firefox reports none ([tracking-techniques.md](../notes/tracking-techniques.md)).
- **Logging tools redact the same way:** Rails replaces filtered parameters with `[FILTERED]`, OpenTelemetry uses `REDACTED` for user info and signed-URL parameters.
- **Google Calendar's `eid`** is base64 of the event ID and the calendar owner's email address (seen by decoding one).

## Limitations

- **Secrets under innocent names or in the path get through:** a magic sign-in link like `/login/<token>`, a key in a parameter called `k`.
- **Some handles are redacted as email addresses:** a fediverse handle in the path (`/@alice@example.social`) looks like one, so its segment goes.
- **Secrets inside structured values are kept,** such as a `state` holding JSON or base64 with a token in it.
- **Some harmless values are redacted,** where the name contains a secret part (`max_tokens`). Per-site scrubbing exceptions, planned ([PLAN.md](../notes/PLAN.md), "Tracker: privacy"), are meant for the useful ones.
- **Redacted and dropped values can't be recovered,** so a scrubbing rule that's too broad loses that detail from history for good.
