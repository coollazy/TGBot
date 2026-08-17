import Foundation

/// getUpdates 迴圈的退避延遲狀態：永不放棄、只是延遲封頂，見架構設計文件 4.1 節。
actor PollingBackoff {
    private var consecutiveFailures = 0
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let maxBackoffSteps: Int
    private let clock: TimeProvider

    init(
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 32.0,
        maxBackoffSteps: Int = 5,
        clock: TimeProvider = SystemTimeProvider()
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxBackoffSteps = maxBackoffSteps
        self.clock = clock
    }

    func delayForNextAttempt() -> TimeInterval {
        let steps = min(consecutiveFailures, maxBackoffSteps)
        return min(baseDelay * pow(2, Double(steps)), maxDelay)
    }

    func recordFailure() {
        consecutiveFailures += 1
    }

    func recordSuccess() {
        consecutiveFailures = 0
    }

    func waitBeforeNextAttempt() async throws {
        try await clock.sleep(for: delayForNextAttempt())
    }
}
