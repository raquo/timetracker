# Time Tracker

An automatic time tracker for macOS: a Swift activity tracker (`tracker/`), with a Scala server and Scala.js UI planned.

## Where things are

- [docs/](docs/README.md): what the app does and why, one doc per topic. Start at docs/README.md for the index.
- [notes/PLAN.md](notes/PLAN.md): progress, open questions, TODOs and ideas not built yet.
- [tracker/README.md](tracker/README.md): building, installing, running and testing the tracker (`swift test` in `tracker/`), and querying its data.
- [docs/conventions.md](docs/conventions.md): timestamps, naming, migrations, code style. Follow it in all code.

## Docs

Follow "How these docs work" in [docs/README.md](docs/README.md): the topic doc layout and the process. In short:

- **Keep docs current without being asked.** Updating the docs is part of any change to code they describe, like updating tests. If you read a doc to implement something, review it afterwards and fix whatever the change made wrong or incomplete, including the Why for decisions made along the way.
- Docs describe the current, reviewed state of the app, not plans (PLAN.md) and not anyone's installation.
- One home per fact: link, don't restate.
