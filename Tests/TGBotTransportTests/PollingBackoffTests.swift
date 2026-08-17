import Testing
@testable import TGBotTransport

@Suite("PollingBackoff")
struct PollingBackoffTests {
    @Test("delay grows then caps, resets to base on success")
    func backoffGrowsAndResets() async {
        let backoff = PollingBackoff(baseDelay: 1, maxDelay: 32, maxBackoffSteps: 5, clock: SystemTimeProvider())
        await backoff.recordFailure()
        let d1 = await backoff.delayForNextAttempt()
        #expect(d1 == 2)

        for _ in 0..<10 { await backoff.recordFailure() }
        let capped = await backoff.delayForNextAttempt()
        #expect(capped == 32)

        await backoff.recordSuccess()
        let reset = await backoff.delayForNextAttempt()
        #expect(reset == 1)
    }
}
