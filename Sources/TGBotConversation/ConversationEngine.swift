import TGBotTransport

/// 每個 chat 的對話狀態透過這個 actor 序列化處理，確保同一 chat 的事件依序執行、
/// 不同 chat 天然並發。見架構設計文件 6.4 節。
///
/// 目前只實作了 resetConversation／pendingCompletions 相關的記錄邏輯（US-5／US-6 的基礎），
/// 真正「把一個 Update 分派給正確的 scene handler、套用 transition」的核心 dispatch 邏輯
/// 待下一階段實作（見架構設計文件第 9 節的完整範例，那是這個 actor 最終要撐起的行為）。
public actor ConversationEngine: ConversationEngineHandle {
    private let stateStore: StateStore

    // 背景任務的待處理完成回呼，刻意存在這裡（純記憶體）而不是 ChatConversationRecord 裡，
    // 見 ChatConversationRecord.swift 的說明：閉包無法 Codable 化，且要獨立於「對話流程本身」
    // 之外，確保 .end／resetConversation() 不會連帶清掉它（US-5／US-6）。
    private var pendingCompletions: [Int64: [String: @Sendable (JobResult) async throws -> Void]] = [:]

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    public func resetConversation(chatID: Int64) async {
        var record = await stateStore.load(chatID: chatID)
        record.reset()
        await stateStore.save(chatID: chatID, record)
        // pendingCompletions 刻意不清
    }

    public func registerPendingCompletion(
        chatID: Int64,
        taskID: String,
        completion: @escaping @Sendable (JobResult) async throws -> Void
    ) async {
        pendingCompletions[chatID, default: [:]][taskID] = completion
    }

    public func deliverBackgroundJobResult(chatID: Int64, taskID: String, result: JobResult) async {
        guard let completion = pendingCompletions[chatID]?.removeValue(forKey: taskID) else { return }
        try? await completion(result)
    }

    /// 把一個 Update 分派給目前 chat 對應的 scene handler。TODO：下一階段實作。
    public func dispatch(update: Update) async {
        fatalError("ConversationEngine.dispatch 尚未實作——這是下一階段的核心工作")
    }
}
