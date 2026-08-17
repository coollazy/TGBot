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

    /// 注意：這個方法會一直阻塞（await 到內部的迴圈 Task 結束）才會 return，
    /// 不是「丟出去背景跑、立刻回來」——TGBot.run() 本來就預期 bot 這個進程要一直
    /// 活著，若 start() 提早 return，呼叫端（EchoBotExample.main()）就會跟著 return，
    /// 整個 process 直接結束，一次輪詢都還沒真的發生。
    /// 這是實際用獨立的 Example 專案跑 `swift run` 才會現形的問題——用同一個 package
    /// 內的單元測試不會發現，因為測試從來不需要「process 一直活著」這件事。
    public func start(onUpdate: @escaping @Sendable (Update) async -> Void) async throws {
        let task = Task {
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
        runLoopTask = task
        await task.value
    }

    public func stop() async {
        runLoopTask?.cancel()
        runLoopTask = nil
    }
}
