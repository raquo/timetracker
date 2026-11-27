/// Delays for retrying something until it succeeds: the first attempt right away, then
/// waits that double from `firstDelayMs` up to `maxDelayMs`, then stay there. With 2 s and
/// 60 s: attempts at 0, 2, 6, 14, 30, 62, 122, 182… s.
struct Backoff: Equatable {
    let firstDelayMs: Int64
    let maxDelayMs: Int64

    /// The wait after attempt number `attempt` (1 for the first) before the next one.
    func delayMs(afterAttempt attempt: Int) -> Int64 {
        var delayMs = firstDelayMs
        var n = 1
        // Stops doubling at the cap, so a long run of attempts can't overflow.
        while n < attempt, delayMs < maxDelayMs {
            delayMs *= 2
            n += 1
        }
        return min(delayMs, maxDelayMs)
    }
}

/// One thing being retried on a `Backoff`: how many attempts so far, and when the next is due.
/// Each wait counts from when the previous attempt was actually made, so a late attempt
/// pushes the later ones back too.
struct BackoffRetry: Equatable {
    let backoff: Backoff
    private(set) var attempts = 0
    private(set) var lastAttemptAtMs: Int64?

    init(_ backoff: Backoff) {
        self.backoff = backoff
    }

    /// When the next attempt is due; nil before the first, which is due at once.
    var nextAttemptAtMs: Int64? {
        lastAttemptAtMs.map { $0 + backoff.delayMs(afterAttempt: attempts) }
    }

    /// Whether to attempt now. Also true if the clock went back past the last attempt, which
    /// would otherwise hold off the next one for as long as it jumped.
    func isDue(atMs nowMs: Int64) -> Bool {
        guard let lastAttemptAtMs, let nextAttemptAtMs else {
            return true
        }
        return nowMs >= nextAttemptAtMs || nowMs < lastAttemptAtMs
    }

    mutating func noteAttempt(atMs nowMs: Int64) {
        attempts += 1
        lastAttemptAtMs = nowMs
    }
}
