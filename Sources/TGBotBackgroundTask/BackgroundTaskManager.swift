import TGBotConversation

/// BackgroundTaskScheduling 的 v1 實作。以獨立的 actor 管理，key 為 (chatID, taskID)。
/// 啟動後任務跑在獨立的 Task，不佔用該 chat 的 conversation actor，因此對話引擎可以
/// 立即回到可回應狀態（滿足 US-3）。見架構設計文件第 7 節。
public actor BackgroundTaskManager: BackgroundTaskScheduling {
    // 已知修正：原本這裡是 `statuses: [String: JobStatus]`，存的是一份「快照」，
    // 只在任務開始（空字串）跟任務完全結束（讀最後一次 progress.lastMessage）各寫
    // 一次——中間 work 閉包呼叫再多次 progress.update(...)，都不會反映到這份快照上，
    // 導致「任務跑到一半查詢進度」這個功能（US-3）實際上是壞的：只有查詢時機剛好
    // 卡在「剛開始」或「已經結束」那一刻才會拿到正確答案，任務執行期間中途查詢
    // 永遠只看得到最初的空字串。這是拿真正花時間的背景任務（不是立刻完成的假任務）
    // 實機測試才踩到的問題，之前的測試都只驗證「完成前／完成後」兩個時間點，沒有
    // 驗證「執行中、progress 已經更新過」這個情況。
    //
    // 修法：不要另外維護一份快照，直接留著 JobProgress 物件本身的參照，
    // status() 每次呼叫都即時讀它「當下」的 lastMessage——沒有同步的問題，
    // 因為根本沒有兩份資料需要保持一致。
    private struct Entry {
        let progress: JobProgress
        var isFinished: Bool
    }
    private var entries: [String: Entry] = [:]

    public init() {}

    public func start(
        chatID: Int64,
        taskID: String,
        work: @escaping @Sendable (JobProgress) async throws -> Void,
        onComplete: @escaping @Sendable (JobResult) async throws -> Void
    ) async {
        let progress = JobProgress()
        entries["\(chatID):\(taskID)"] = Entry(progress: progress, isFinished: false)

        Task {
            let result: JobResult
            do {
                try await work(progress)
                result = .success
            } catch {
                result = .failure(error)
            }
            await self.markFinished(chatID: chatID, taskID: taskID)
            try? await onComplete(result)
        }
    }

    public func status(chatID: Int64, taskID: String) async -> JobStatus? {
        guard let entry = entries["\(chatID):\(taskID)"] else { return nil }
        let lastMessage = await entry.progress.lastMessage
        return JobStatus(taskID: taskID, lastMessage: lastMessage, isFinished: entry.isFinished)
    }

    private func markFinished(chatID: Int64, taskID: String) async {
        entries["\(chatID):\(taskID)"]?.isFinished = true
    }
}
