/// Context／GlobalContext 用來安全地跟對話引擎溝通的窄介面（不暴露整個引擎的內部細節）。
/// 真正的實作是每個 chat 一個 actor，所有操作最終都會排進該 chat 自己的序列化佇列，
/// 見架構設計文件 6.4／7.1 節。完整的引擎 dispatch 邏輯待下一階段實作，這裡先定義介面。
package protocol ConversationEngineHandle: Sendable {
    func resetConversation(chatID: Int64) async

    func registerPendingCompletion(
        chatID: Int64,
        taskID: String,
        completion: @escaping @Sendable (JobResult) async throws -> Void
    ) async

    func deliverBackgroundJobResult(chatID: Int64, taskID: String, result: JobResult) async
}
