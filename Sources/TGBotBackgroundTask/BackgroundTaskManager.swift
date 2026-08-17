import TGBotConversation

/// BackgroundTaskScheduling 的 v1 實作。以獨立的 actor 管理，key 為 (chatID, taskID)。
/// 啟動後任務跑在獨立的 Task，不佔用該 chat 的 conversation actor，因此對話引擎可以
/// 立即回到可回應狀態（滿足 US-3）。見架構設計文件第 7 節。
public actor BackgroundTaskManager: BackgroundTaskScheduling {
    private var statuses: [String: JobStatus] = [:]

    public init() {}

    public func start(
        chatID: Int64,
        taskID: String,
        work: @escaping @Sendable (JobProgress) async throws -> Void,
        onComplete: @escaping @Sendable (JobResult) async throws -> Void
    ) async {
        let progress = JobProgress()
        statuses["\(chatID):\(taskID)"] = JobStatus(taskID: taskID, lastMessage: "", isFinished: false)

        Task {
            let result: JobResult
            do {
                try await work(progress)
                result = .success
            } catch {
                result = .failure(error)
            }
            await self.markFinished(chatID: chatID, taskID: taskID, progress: progress)
            try? await onComplete(result)
        }
    }

    public func status(chatID: Int64, taskID: String) async -> JobStatus? {
        statuses["\(chatID):\(taskID)"]
    }

    private func markFinished(chatID: Int64, taskID: String, progress: JobProgress) async {
        let lastMessage = await progress.lastMessage
        statuses["\(chatID):\(taskID)"] = JobStatus(taskID: taskID, lastMessage: lastMessage, isFinished: true)
    }
}
