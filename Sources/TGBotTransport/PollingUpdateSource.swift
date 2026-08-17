import Foundation
import Logging

/// v1 的 UpdateSource 實作：持續呼叫 getUpdates，失敗時走 4.1 節的退避重試策略、永不放棄。
public final class PollingUpdateSource: UpdateSource, @unchecked Sendable {
    private let apiClient: TelegramAPIClient
    private let backoff: PollingBackoff
    private let logger: Logger
    private var runLoopTask: Task<Void, Never>?

    public init(
        apiClient: TelegramAPIClient,
        clock: TimeProvider = SystemTimeProvider(),
        logger: Logger = Logger(label: "TGBotTransport.Polling")
    ) {
        self.apiClient = apiClient
        self.backoff = PollingBackoff(clock: clock)
        self.logger = logger
    }

    public func start(onUpdate: @escaping @Sendable (Update) async -> Void) async throws {
        runLoopTask = Task {
            var offset: Int? = nil
            while !Task.isCancelled {
                do {
                    let updates = try await apiClient.getUpdates(offset: offset, timeout: 25)
                    await backoff.recordSuccess()
                    for update in updates {
                        await onUpdate(update)
                        // getUpdates 的 offset 語意是「回傳這個值之後的所有 update」，
                        // 所以要設成已處理的最大 update_id + 1，避免下次重複拿到同一筆
                        offset = Int(update.updateID) + 1
                    }
                } catch {
                    logger.error("getUpdates failed, backing off: \(error)")
                    await backoff.recordFailure()
                    try? await backoff.waitBeforeNextAttempt()
                }
            }
        }
    }

    public func stop() async {
        runLoopTask?.cancel()
        runLoopTask = nil
    }
}
