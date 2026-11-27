# Idle and away

How the tracker records that nobody is using the Mac, and how the server is meant to turn that into "away". One concern across both pieces: the tracker records raw facts (input-idle, screen locked, presence signals), the server decides what counts as away. Columns: [data-model.md](data-model.md).

## Behaviour

- **Input-idle:** `is_input_idle = 1` inside a stretch of at least 60 s without input (keyboard, mouse, trackpad). The stretch starts at the last input, not when the tracker noticed it (*backdated*).
- **Screen locked:** `is_screen_locked = 1` while the screen is locked. App, window and page attributes are NULL then, and `is_input_idle` is 0: a locked row is locked, not idle.
- **Presence signals:** whether something prevents display sleep (a video, a presentation, a call, or a keep-awake tool), and whether the camera or mic is in use, with info about who holds them. They show the user may be there without touching the Mac. See [Presence signals](#presence-signals).
- **Sleep** is a gap, not a row ([sampling.md](sampling.md)).
- **Away** isn't recorded by the tracker at all. The server decides it from the rows above (see [Away](#away-server)).

## Input-idle

- **Source:** macOS's idle timer, `CGEventSource.secondsSinceLastEventType(.combinedSessionState, anyInputEventType)`, which says only how long ago the last input was ([tracker-principles.md](tracker-principles.md): no keylogging). Code: `Sampler`.
- **Threshold:** 60 s, checked at every sample.
- **Going idle is noticed late:** the first sample after 60 s without input, so at 60–65 s.
- **Backdating:** the idle row starts at the last input. Example: last input at 10:00:00; at 10:01:00 the tracker sees 60 s without input, and records 10:00:00 onwards as idle. Code: `Recorder`.
  - The row that was open when idle was noticed ends at the last input.
  - **If the first idle sample also shows another change** (a window title changed while the user was away), the old state gets an idle row of its own, from the last input to when the change was first seen; the new state follows, idle too. So the idle row has what was on screen at the time, not what was on screen when idle was noticed.
- **Coming back** is noticed at the next sample after the input: at once for a click (600 ms) or app switch, else at the poll, up to 5 s later. The idle row runs until then.

**Idle stretches have their real length.** Consecutive idle rows are one input-free stretch, and it starts at the last input. So the server can apply any away threshold of 60 s or more to all history (90 s and 7 min as well as 5 min): it checks whether the stretch is at least that long. Thresholds under 60 s can't be applied, since shorter stretches aren't marked.

## Lock and unlock

- **Signals:** the `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` distributed notifications; each triggers a sample at once. At startup (launchd restarting the tracker while the screen is locked, when only the unlock notification would come), the tracker reads the state from `CGSessionCopyCurrentDictionary` (`CGSSessionScreenIsLocked`). Code: `Tracker`.
- **While locked,** a sample reads nothing from apps: the row has only `is_screen_locked = 1`.
- **Unlocking without input** (Apple Watch; Touch ID if macOS's idle timer doesn't count it): after the unlock the user may not have touched anything for minutes, so the first sample after the unlock is already idle. Its idle stretch is **not backdated into the locked row.** The locked row ends at the unlock, and the idle row starts there. The screen was locked all along until the unlock, and a locked row is never turned into an idle one.

## Presence signals

Signals that the user may be at the Mac without touching it (a video, a call), so the away rule can tell that from "gone". Recorded with who holds them, since keep-awake tools (Amphetamine, `caffeinate -d`) and always-on mic apps (Krisp) hold the same signals all day; the server decides which holders count. Columns: [data-model.md](data-model.md#presence-signals). Code: `PresenceReader`.

| Signal | Column | Source |
|---|---|---|
| Display sleep held off | `display_sleep_holders`: app, assertion name, proxy | power assertions of type `PreventUserIdleDisplaySleep` (or legacy `NoDisplaySleepAssertion`, via `AssertionTrueType`) at level 255 (on), from `IOPMCopyAssertionsByProcess`. A proxy (caffeinate) sets `AssertionOnBehalfOfPID`: that process is the holder, the proxy is `via` |
| Mic in use | `mic_holders`: app | CoreAudio's audio process list (macOS 14+): processes with input running (`kAudioProcessPropertyIsRunningInput`) from at least one device (`kAudioProcessPropertyDevices`). An audio tap, which records other apps' sound, reports input running with no device, so it doesn't count |
| Camera in use | `is_camera_in_use` | CoreMediaIO: any camera running somewhere. No holders: no public API says which process uses a camera |

- **Holders** are `tracker_app` rows, like the frontmost app. Helper processes are recorded as themselves (`com.apple.WebKit.GPU` for Safari); their `app_path` shows the app they belong to.
- **Read on the poll** (every 5 s), and on wake, lock and unlock; other samples reuse the last read. NULL while the screen is locked or a read fails. Code: `Tracker.refreshPresence()`.
- **Settled like any change:** a read that differs from the one before is read again by the next sample (the [settling](sampling.md#settling) re-sample, ~400 ms later), so a read that failed once, or a hold gone by then, isn't recorded. This extra read happens only when presence changed.
- **Mic shortcut:** while no device that has an input is running (`kAudioDevicePropertyDeviceIsRunningSomewhere`), the mic holders are `[]` without listing processes. Only a shortcut: "running" covers output too, so a headset playing sound, or Krisp, keeps it from applying.
- **Cost** (macOS 15.6, CPU including the daemons that answer): display sleep holders ~1.1 ms (mostly `powerd`), the mic shortcut's device check ~1.7 ms (mostly `coreaudiod`), the camera ~0.04 ms. Listing mic holders ~14 ms with 35 audio processes (~2 ms ours, ~12 ms `coreaudiod`), one round trip per process, so it grows with the number of apps using audio; the list includes every process that has connected to CoreAudio, mostly idle. Per poll: ~3 ms, or ~17 ms when the shortcut doesn't apply, 0.06% to 0.35% of one core. No permission needed: nothing opens a device.

## Away (server)

**The tracker never decides what counts as away.** It records how long input stopped and whether the screen was locked. The server's away rule reads those, so the rule can change and apply to all history.

The away rule isn't built yet (the server isn't). The planned first version is in [PLAN.md](../notes/PLAN.md) ("Away rule"): no input for N minutes counts as away, unless a [presence signal](#presence-signals) shows the user is still there, from a holder that counts (not a keep-awake tool).

## Why

- **60 s, in the tracker.** Users are unlikely to want to count shorter pauses as away, so recording them gains nothing. And it would cost: each input-free stretch longer than the threshold gets rows of its own: it ends the open row, adds an idle row, and a new row starts when input resumes. A lower threshold would do that at every short pause, so more rows and writes (row churn, [tracker-principles.md](tracker-principles.md)). Checking costs the same at any threshold: the idle time is read on every sample anyway. Not measured. The price: the server can't apply an away threshold below it.
- **Backdating.** Without it, every idle stretch would begin with 60 s recorded as active, and its recorded length would be 60 s short, so thresholds couldn't be applied exactly.
- **An idle row of its own for the old state.** Without it, the backdated row would carry the attributes seen when idle was noticed, a row that never existed ([record-consistency.md](record-consistency.md), #5).
- **Locked never becomes idle.** The screen was locked until the unlock; an idle row there would describe a moment that didn't happen.
- **Read on the poll only.** The away rule works in minutes, so 5 s late doesn't matter, and a value carried into a row started by another change is less noise. Reading on every sample would cost 3–17 ms of CPU each time. No notification exists for display sleep, nor for a process starting input on a device that's already running, so sampling on device notifications too would make only some changes earlier.
- **Away in the server.** The tracker records raw facts and the server interprets them ([architecture.md](architecture.md)), so the away rule can change and apply to all history.

## Background

- **Virtual devices count:** a virtual camera (OBS) or mic (Krisp, Microsoft Teams Audio) running is "in use", like a real one.
- **Siri** (`corespeechd`) has input running only for the few seconds it listens after being invoked, not while idle.

## Limitations

- **Backdating reaches only into the open row.** If a row closed after the last input (a window title changed while the user was away), the rows before that change stay not idle, so the stretch looks shorter ([record-consistency.md](record-consistency.md), #5).
- **Presence changes are up to 5 s late** (the poll), and a hold that starts and ends between two polls (a few seconds of dictation) isn't seen. One a poll catches and the confirming read still sees lasts at least until the next poll.
- **The camera has no info on holders,** so a camera held by an app all day can't be told apart from a call.
- **Not yet checked with real calls and videos:** which names browsers and call apps give their assertions, whether call apps keep the mic running while muted, and whether any name contains page or media titles (which would need scrubbing). Checklist in [PLAN.md](../notes/PLAN.md).
- **Fast user switching isn't handled.** While another macOS user is active, the tracker keeps sampling, and that time is recorded as idle in whatever app was frontmost.
- **Not yet verified:** whether a Touch ID unlock counts as input for macOS's idle timer. Either way it's recorded correctly: if not, it takes the unlock-without-input path above.
