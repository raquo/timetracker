import Testing
@testable import TrackerCore

struct BackoffTests {
    private let backoff = Backoff(firstDelayMs: 2_000, maxDelayMs: 60_000)

    @Test func delaysDoubleUpToTheCap() {
        #expect((1...9).map { backoff.delayMs(afterAttempt: $0) } == [2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000, 60_000])
        // Many attempts don't overflow.
        #expect(backoff.delayMs(afterAttempt: 10_000) == 60_000)
    }

    @Test func capBelowTheFirstDelay() {
        #expect(Backoff(firstDelayMs: 5_000, maxDelayMs: 3_000).delayMs(afterAttempt: 1) == 3_000)
    }

    @Test func firstAttemptIsDueAtOnce() {
        let retry = BackoffRetry(backoff)
        #expect(retry.isDue(atMs: 0))
        #expect(retry.nextAttemptAtMs == nil)
        #expect(retry.attempts == 0)
    }

    @Test func eachWaitCountsFromTheLastAttempt() {
        var retry = BackoffRetry(backoff)
        retry.noteAttempt(atMs: 1_000)
        #expect(retry.nextAttemptAtMs == 3_000)
        #expect(!retry.isDue(atMs: 2_999))
        #expect(retry.isDue(atMs: 3_000))
        // Made late: the next wait (4 s) counts from then.
        retry.noteAttempt(atMs: 10_000)
        #expect(retry.attempts == 2)
        #expect(retry.nextAttemptAtMs == 14_000)
        #expect(!retry.isDue(atMs: 13_999))
        #expect(retry.isDue(atMs: 14_000))
    }

    @Test func clockGoingBackMakesItDue() {
        var retry = BackoffRetry(backoff)
        retry.noteAttempt(atMs: 10_000)
        #expect(retry.isDue(atMs: 9_999))
    }
}
