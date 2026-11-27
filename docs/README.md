# Time Tracker

An automatic time tracker for macOS, in the spirit of [Timing](https://timingapp.com): a lightweight activity tracker, a Scala server, and a web UI for rules, timelines and reports.

This folder describes what the system does and why. Plans, progress and open questions are in [notes/PLAN.md](../notes/PLAN.md). Building and running the tracker: [tracker/README.md](../tracker/README.md).

## The pieces

- **Tracker** (Swift): records what's on screen into SQLite.
- **Server** (Scala): turns raw activity into projects via rules, serves reports.
- **UI** (Scala.js): rules, timeline, reports.

How they fit together: [architecture.md](architecture.md).

## Docs

Hub:
- [architecture.md](architecture.md): the pieces, the shared database, isolation, settings the tracker reads.
- [conventions.md](conventions.md): timestamps, naming, migrations.

Tracker:
- [tracker-principles.md](tracker-principles.md): no keylogging, record generously, privacy before writing, lightweight, consistent rows.
- [data-model.md](data-model.md): what the tracker's tables mean.
- [sampling.md](sampling.md): when the tracker samples, settling, sleep and wake, late boundaries.
- [record-consistency.md](record-consistency.md): how every row stays one real moment; the known ways that can break.
- [idle-and-away.md](idle-and-away.md): input-idle and backdating, lock and unlock, and the server's away rule.
- [page-reading.md](page-reading.md): finding the content page in a window, the page reading mode per app (on, off, probing), the Electron tree switch, cost.
- [privacy.md](privacy.md): overview of every privacy measure (no keylogging, scrubbing before writing, data stays local), and what's planned.
- [url-scrubbing.md](url-scrubbing.md): fragments, redaction, `AXDocument` URLs, decided exceptions.
- [diagnostics.md](diagnostics.md): the `--dump-ax` tool, Accessibility fixtures and replay tests, checking a new app.
- [end-to-end-tests.md](end-to-end-tests.md): the real tracker recording a scripted test app, a throwaway Chrome and a throwaway Firefox, and what that can and can't cover.

Research (to be reorganized):
- [tracking-techniques.md](../notes/tracking-techniques.md): how the tracker can get data from macOS, and what specific apps expose.
- [electron-and-claude.md](../notes/electron-and-claude.md): Electron apps' web Accessibility tree, and the Claude desktop app.

## How these docs work

- **One doc per topic.** A topic is one feature or concern (sampling, idle, page reading), even when it spans tracker and server. Make a shared doc only for facts that several topics use (the data model, conventions), or for a part too big to stay inside its topic.
- **Present tense, current state.** No history except where it explains a decision; git keeps the rest.
- **One home per fact.** Other docs link to the topic rather than restating it, with at most a one-line summary so the reader knows whether to follow the link. Link to the topic or section, not to a particular sentence, so links survive rewording. Link sections by anchor (`sampling.md#late-boundaries`).
- **They describe the app, not anyone's installation.** The app is meant to run on any Mac. So no run status, install dates, data resets, row counts or settings on the developer's machine: those go in PLAN.md, or nowhere. An observation made on a particular Mac belongs here only as evidence for how the app behaves or why, said as such ("observed on macOS 15 with Firefox 133"), not as a description of that Mac.

### How a topic doc is laid out

The shape that the existing docs share. Copy it, not a fixed template: headings follow the topic, and a section that would be empty is left out.

- **Title, then an intro paragraph** saying what the doc covers and linking its neighbours ("What the rows mean: data-model.md").
- **Behaviour first:** what the app does, as seen in the data or the UI, with the numbers that matter (60 s, 5 s, 20 s), and links to the sections with the details.
- **Then one section per mechanism or sub-feature,** named after it: "When the tracker samples", "Settling", "Watermark", "One tracker per database", "Lock and unlock". Each opens with a sentence or two framing it, then the details, naming the code involved ("Code: `Settler`") so readers can find it. Where a section's point is a claim, the heading can say it ("One database, split by owner").
- **Then the fixed closing sections, in this order, each optional:**
  - **Why:** one bullet per decision: the decision in bold, then the reason, then what we rejected and why. This keeps a later change from undoing a decision by accident, so record rejected alternatives even when they seem obvious.
  - **Background:** facts about the outside world the topic relies on (how macOS, an API or an app behaves), with how we know (documentation, or observed on which version). Kept apart from decisions so they can be checked on their own.
  - **Limitations:** known gaps and failure cases of what's built, and what happens in each. Plans to fix them stay in PLAN.md.

Doc kinds that don't fit this shape use their own, consistently within the doc. tracker-principles.md gives each principle **Rule** / **In practice** / **Why** (left out where the reason is self-evident). data-model.md has one section per table, with a column table. architecture.md and conventions.md are sections of claims, each with its reason.

Style:
- **Write for a reader new to the topic,** in plain English. Introduce a concept before its details, and give each thing one name.
- **Use whatever form reads best:** paragraphs for reasoning, bullets for lists, tables for things compared along the same columns, concrete examples (times, titles, URLs) where appropriate. Bold helps skimming; use it sparingly.

### Process

- **Written after implementation,** once the change has been reviewed. Changes start from a prompt that may be rough, not from a spec: implement, review, then write down what was settled. Features that aren't built yet stay in PLAN.md as ideas.
- **Keep docs current as part of the work, without being asked.** A change to code that a doc describes includes updating that doc, in the same piece of work, just like updating tests. At the very least: **if you read a doc to implement something, review that doc afterwards** and update whatever the change made wrong or incomplete, including the Why for any decision made along the way.
- **Check facts against the code;** notes and PLAN.md can be out of date. Record only reasons that were actually given or follow from the code.
- **When a topic doc is written or grows,** move the matching content out of PLAN.md and notes/ (leave a link), and update the index above.
- **Check links** after renaming or moving sections.

## Why not ActivityWatch

We evaluated v0.14.3 (November 2026) and rejected it:

- **Categories can't match on URL.** Rules only see the window watcher's `app` and `title`, and the browser extensions' `url` is never joined in (open since 2019, aw-webui#151). Most of our Timing rules are domain rules.
- **No document or file paths.**
- **One regex per category** is the only rule type.
- **Weak UI.**
