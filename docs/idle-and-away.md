# Idle and away

How the tracker records that nobody is using the Mac, and how the server is meant to turn that into "away". One concern across both pieces: the tracker records raw facts (input-idle, screen locked), the server decides what counts as away. Columns: [data-model.md](data-model.md).

## Behaviour

- **Input-idle:** `is_input_idle = 1` inside a stretch of at least 60 s without input (keyboard, mouse, trackpad). The stretch starts at the last input, not when the tracker noticed it (*backdated*).
- **Screen locked:** `is_screen_locked = 1` while the screen is locked. App, window and page attributes are NULL then, and `is_input_idle` is 0: a locked row is locked, not idle.
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

## Away (server)

**The tracker never decides what counts as away.** It records how long input stopped and whether the screen was locked. The server's away rule reads those, so the rule can change and apply to all history.

The away rule isn't built yet (the server isn't). The planned first version, and the tracker signals it needs, are in [PLAN.md](../notes/PLAN.md) ("Away rule"; "Video / call / camera / mic"): no input for N minutes counts as away, unless something shows the user is still there without touching the Mac (a video or call holding off display sleep, the camera or mic in use). The columns for those signals exist (`has_display_sleep_assertion`, `is_camera_in_use`, `is_mic_in_use`) and are NULL until they're recorded.

## Why

- **60 s, in the tracker.** Users are unlikely to want to count shorter pauses as away, so recording them gains nothing. And it would cost: each input-free stretch longer than the threshold gets rows of its own: it ends the open row, adds an idle row, and a new row starts when input resumes. A lower threshold would do that at every short pause, so more rows and writes (row churn, [tracker-principles.md](tracker-principles.md)). Checking costs the same at any threshold: the idle time is read on every sample anyway. Not measured. The price: the server can't apply an away threshold below it.
- **Backdating.** Without it, every idle stretch would begin with 60 s recorded as active, and its recorded length would be 60 s short, so thresholds couldn't be applied exactly.
- **An idle row of its own for the old state.** Without it, the backdated row would carry the attributes seen when idle was noticed, a row that never existed ([record-consistency.md](record-consistency.md), #5).
- **Locked never becomes idle.** The screen was locked until the unlock; an idle row there would describe a moment that didn't happen.
- **Away in the server.** The tracker records raw facts and the server interprets them ([architecture.md](architecture.md)), so the away rule can change and apply to all history.

## Limitations

- **Backdating reaches only into the open row.** If a row closed after the last input (a window title changed while the user was away), the rows before that change stay not idle, so the stretch looks shorter ([record-consistency.md](record-consistency.md), #5).
- **Fast user switching isn't handled.** While another macOS user is active, the tracker keeps sampling, and that time is recorded as idle in whatever app was frontmost.
- **Not yet verified:** whether a Touch ID unlock counts as input for macOS's idle timer. Either way it's recorded correctly: if not, it takes the unlock-without-input path above.
