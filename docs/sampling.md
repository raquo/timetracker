# Sampling

When the tracker looks at the screen, and how what it sees becomes `tracker_interval` rows. What the rows mean: [data-model.md](data-model.md). What the rows guarantee, and the known ways that can break: [record-consistency.md](record-consistency.md).

## Behaviour

- **A sample** reads what's on screen right now: the frontmost app, its focused window (title, role, main / full screen, document), the page in it where pages are read, how long since the last input, whether the screen is locked, and the [presence signals](idle-and-away.md#presence-signals) (display sleep held off, camera, mic). Code: `Sampler` → `Snapshot`.
- **Equal samples extend the open row; a changed sample ends it and starts a new one.** So how often the tracker samples doesn't add rows; only changes do.
- **Changes are recorded at the time they were first seen,** usually within a second of happening, at most ~5 s later (see [Late boundaries](#late-boundaries)).
- **A change has to hold for two samples** before it's recorded (settling), so in-between states don't get rows.
- **Sleep, a hang or a stopped tracker leave a gap,** never a row stretched across the missing time.

## When the tracker samples

Events, with a slow poll as a backstop. Code: `Tracker`, `WindowObserver`.

| Trigger | Sample taken | Catches |
|---|---|---|
| App activation (`NSWorkspace.didActivateApplication`) | at once | app switches |
| Focused window changed, window title changed (`AXObserver` on the frontmost app) | 300 ms after the first event (see below) | window switches, browser tab switches, documents opened |
| Where pages are read, also: keyboard focus moved (`AXFocusedUIElementChanged`), the page's title changed, a page finished loading (`AXLoadComplete`, app-wide) | same | apps whose window title stays the same while the page changes (Claude switching conversations) |
| Any left click, anywhere (`leftMouseUp`) | 600 ms after the first click (see below) | changes that send no Accessibility event; the delay gives the app time to react to the click |
| Lock, unlock, wake | at once | see [idle-and-away.md](idle-and-away.md) |
| Poll | every 5 s | everything else: URL-only changes, going idle and back, [presence signals](idle-and-away.md#presence-signals) (read only then and on a few events, see there) |
| A probe of the frontmost app's window comes due ([page-reading.md](page-reading.md#probing)) | when due | pages of an app not decided on yet, in a tree that was still empty at the previous probe |
| SIGUSR1 | at once | nothing in normal use: for the [end-to-end test](end-to-end-tests.md) |

**Test hooks.** `TIMETRACKER_POLL_SECONDS` sets the poll interval (a positive whole number of seconds; anything else stops the tracker at startup), and SIGUSR1 asks for a sample. The end-to-end test sets the poll to an hour, so a missed event fails instead of being covered up by a poll that happens to come right after, and asks for samples where a step's change sends no event. Code: `TrackerMain.pollInterval`, `Tracker`.

**Several events, one sample.** The first event schedules a sample 300 ms later; events that arrive before it's taken add nothing, since that sample will see their effect too. Example: a page that sets its title three times within 200 ms while loading gets one sample, 300 ms after the first change, not three. The timer isn't restarted by later events, so a stream of events (a title that changes every 100 ms for 2 s) still gets a sample every ~300 ms. Clicks work the same way, with 600 ms, and separately from events.

Only the fact of a click is used, never its position, target or button ([tracker-principles.md](tracker-principles.md): no keylogging). The click monitor needs the Accessibility permission, like the window observers.

## Settling

**Settling** is waiting, after a change is seen, until what's on screen stops changing (*settles*) before recording it. While an app switches tabs, pages or windows, it passes through in-between states that last a fraction of a second, such as the new URL shown with the old title. Settling keeps those out of the rows. Code: `Settler`.

A sample that differs from the open row isn't recorded right away:

1. The tracker samples again 400 ms later.
2. **Two samples at least 250 ms apart that agree confirm the change.** It's recorded from when the change was *first seen*, not when it was confirmed, so settling delays the write but doesn't move the boundary.
3. **A change that reverts** before it's confirmed is dropped: the open row just continues.
4. **A change that never settles** (e.g. a title that changes faster than settling can confirm it, such as a progress percentage updating several times a second) is recorded after 3 s anyway, as the latest state that two samples at least 250 ms apart agreed on. If no two agreed, the last sample is recorded. If that wasn't the current sample, the current one starts a new pending change.
5. **A change still pending when sampling stops for over 20 s** (sleep, a hang) is forgotten: after the gap it counts as first seen again, so its row can't start before the gap.
6. **On sleep and quit,** a pending change is dropped, since it can't be confirmed any more. Where the open row then ends: see "From samples to rows".

## From samples to rows

- **The open row lives in memory.** Each unchanged sample moves its end; the end is written to disk every 30 s. So a crash loses at most 30 s, and the newest row on disk can lag by that much ([data-model.md](data-model.md)). Code: `Recorder`.
- **A change closes the open row and inserts a new one,** as two separate writes ([record-consistency.md](record-consistency.md)).
- **Before quit (SIGTERM, SIGINT) and sleep,** the tracker takes one last sample and closes the open row, so the time since the last poll isn't lost. Usually the row ends at that sample. If something changed that isn't confirmed yet, the change isn't recorded (see "Settling"), but the row still ends when the change was first seen, since the old state was on screen until then. Example: the open row is Safari on page A, last sampled at 10:00:00; the tracker quits at 10:00:04, and its last sample sees page B. The row for A ends at 10:00:04, and B isn't recorded. Two exceptions: if the change is going idle, the row ends at the last input if that came after its last sample, else at that sample ([idle-and-away.md](idle-and-away.md)); and if the change was first seen over 20 s after the row's last sample, the row ends at that sample (the gap rule in "Sleep and wake"). A row opened by the last sample has no duration and is deleted. Code: `Recorder.close(pending:)`.

## Sleep and wake

- **On sleep** (`NSWorkspace.willSleep`) the tracker takes its last sample, closes the open row, saves page probe counts ([data-model.md](data-model.md)), and stops sampling until wake.
- **On wake** (`didWake`) it samples at once, which opens a new row.
- **The 20 s gap rule:** if two consecutive samples are more than 20 s apart (4 polls), the open row ends at the earlier sample and a new row starts. That's what makes sleep correct even when the tracker never handles `willSleep` (see [Background](#background)). It also covers anything else that stops sampling: a suspended process, or a sample stalled by a hung app.

## Late boundaries

A boundary is recorded when the change is noticed, which is after it happened:

- after an Accessibility event: ~300 ms;
- after a click: 600 ms;
- with neither (a URL that changes without a load or title change, a page title change in WebKit, input resuming after idle): up to the 5 s poll. Which page changes send no events: [page-reading.md](page-reading.md#limitations). Presence signals always wait for the poll ([idle-and-away.md](idle-and-away.md#limitations)).

Settling records from the first sighting, so it adds nothing here. The poll interval bounds the worst case, which is why it shouldn't be raised lightly. The poll and the delays above are timers, which is why the tracker opts out of App Nap: [architecture.md](architecture.md#operating-environment).

## Accessibility timeouts

Every Accessibility call times out after 0.5 s, so an app that doesn't answer can't stall sampling. The timeout is set once, globally (see [Background](#background)). Samples run on the tracker's own queue, never on the main thread.

## Why

- **On quit, an unconfirmed change ends the open row but isn't recorded.** Ending the row at its last sample instead would lose the time until the change was seen, up to a poll interval.
- **Events plus a slow poll, not a fast poll.** Events catch most changes within a few hundred ms at almost no cost; a fast poll would cost CPU all day for the same boundaries ([tracker-principles.md](tracker-principles.md): lightweight). The poll is a backstop for what sends no event.
- **Clicks as a trigger.** Some apps change what they show without any Accessibility event (Claude, clicking another conversation). Without the click trigger those changes would wait for the poll. A click is the only input event used, and only as "a click happened".
- **One sample for several events.** Pages update their title several times while loading; sampling on each event would cost a sample per update. Not restarting the timer on each event keeps the delay bounded, so a page that never stops updating still gets sampled.
- **Settling instead of recording every sample.** Browsers commit the new URL before the new title (or single-page apps the other way round), and app switches pass through mixed states. One sample in between would record one page's title with another page's URL, a row that never existed. A 400 ms delay before writing is cheap; a mismatched row is permanent.
- **Backdating confirmed changes to the first sighting.** Settling should cost latency, not accuracy.
- **Ending the row at the last sample after a gap.** Stretching it across the gap would claim activity during sleep. The last sample is the last moment the tracker saw that state.
- **20 s.** Four missed polls: enough margin that timer jitter or an occasional slow or failed sample doesn't split a row by mistake.

## Background

- **macOS doesn't wait for apps to handle `willSleep`.** The notification may be handled only after wake, if at all, so the final sample before sleep can't be relied on.
- **`AXUIElementSetMessagingTimeout` on one element covers only that element,** not windows and children read from it, which wait ~6 s each on a hung app. Set on `AXUIElementCreateSystemWide()`, it becomes the default for every element.
- **ActivityWatch's defaults, for comparison:** its window watcher polls every 1 s, its AFK watcher every 5 s; each poll is a heartbeat merged into the last event.

## Limitations

- **In-between states longer than settling** still get rows of their own. Example: Firefox sometimes titles a window with just the app's name for 2–5 s while switching tabs.
- **A failed Accessibility subscription isn't retried.** If adding a notification fails (an app that has only just launched), that app's window and title changes are caught only by clicks and the poll until the user switches away and back.
- **A sleep without a wake** would stop recording until the next sleep: after `willSleep` the tracker samples nothing until `didWake`. Not observed, and unknown whether macOS can do this.
- **Rows shorter than a second** can still come from a state that held only briefly but long enough to be confirmed. The server is expected to filter these.
