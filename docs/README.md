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

Research (to be reorganized):
- [tracking-techniques.md](../notes/tracking-techniques.md): how the tracker can get data from macOS, and what specific apps expose.
- [electron-and-claude.md](../notes/electron-and-claude.md): Electron apps' web Accessibility tree, and the Claude desktop app.

Not yet moved out of PLAN.md: sampling, record consistency, idle, page reading, privacy, diagnostics.

## How these docs work

- **One doc per topic.** A topic doc holds the behaviour, how it works, why (decisions and the alternatives we rejected), outside-world facts it depends on, and known limits. Facts used by several topics go in a shared doc instead.
- **Present tense, current state.** No history except where it explains a decision; git keeps the rest.
- **Written after implementation,** once a change has been reviewed. Features that aren't built yet stay in PLAN.md as ideas.
- **One home per fact.** Other docs link to the topic rather than restating it.
- **They describe the app, not anyone's installation.** The app is meant to run on any Mac. So no run status, install dates, data resets, row counts or settings on the developer's machine: those go in PLAN.md, or nowhere. An observation made on a particular Mac belongs here only as evidence for how the app behaves or why, said as such ("observed on macOS 15 with Firefox 133"), not as a description of that Mac.

## Why not ActivityWatch

We evaluated v0.14.3 (November 2026) and rejected it:

- **Categories can't match on URL.** Rules only see the window watcher's `app` and `title`, and the browser extensions' `url` is never joined in (open since 2019, aw-webui#151). Most of our Timing rules are domain rules.
- **No document or file paths.**
- **One regex per category** is the only rule type.
- **Weak UI.**
