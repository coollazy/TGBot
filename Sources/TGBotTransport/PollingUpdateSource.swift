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
            // 同一個 chat 的 update 要嚴格保序，不同 chat 之間要能真正並發——見 README
            // 「已知限制」修復記錄。做法：每筆 update 各自丟一個 Task 處理，但同一個
            // chatID 的 Task 鏈式串接（後面的先 await 前面那個做完）。這個字典是輪詢
            // 迴圈自己的本地變數，只被這個單一執行緒同步讀寫（讀前一個、寫新的都在同一段
            // 沒有 await 的程式碼裡完成），跨批次 getUpdates 也持續保留，不會有 race，
            // 保序這件事在這裡就已經釘死，不依賴之後排程器實際執行的先後順序。
            // 刻意不清理已完成的舊 entry：清理要在 Task 完成後、從另一個執行緒做，會替
            // 這個目前無鎖的字典引入新的 race，不值得為了省一點記憶體冒這個險——量級上
            // 只是「歷來出現過的 chat 數」，對長跑 bot 可接受。
            var lastTaskByChat: [Int64: Task<Void, Never>] = [:]
            while !Task.isCancelled {
                do {
                    let updates = try await apiClient.getUpdates(offset: offset, timeout: 25)
                    await backoff.recordSuccess()
                    for update in updates {
                        let previous = lastTaskByChat[update.chatID]
                        let chatTask = Task {
                            _ = await previous?.value
                            await onUpdate(update)
                        }
                        lastTaskByChat[update.chatID] = chatTask
                        // getUpdates 的 offset 語意是「回傳這個值之後的所有 update」，
                        // 所以要設成已處理的最大 update_id + 1，避免下次重複拿到同一筆。
                        // 不再等 onUpdate 處理完才推進——處理已經丟給上面的 Task 並發跑，
                        // 這裡只要確保下一次 getUpdates 不會重複拿到同一筆就好。
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
