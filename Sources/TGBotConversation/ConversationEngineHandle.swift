import Foundation

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

    /// 把背景任務 onComplete 回傳的 Transition 套用回這個 chat 的對話狀態（對應需求書 US-6
    /// 「接續詢問下一步」）。只有 record.activeScene 仍然等於 sceneName 時才會真的套用——
    /// 使用者可能在任務跑的期間已經 /cancel 或切去別的流程，這種情況安靜忽略，不強行推進
    /// 一個使用者已經不在裡面的流程。見 Context.startBackgroundJob。
    ///
    /// baselineSessionData：任務啟動當下的 session 快照，用來判斷套用當下資料庫裡的
    /// session 是不是還是同一份——不一樣的話代表使用者在任務執行期間透過正常 dispatch()
    /// 又編輯過 session，這種情況要保留使用者較新的那份，不能用 newSessionData（任務
    /// 啟動當下那份舊快照）蓋掉。nil 代表當初編碼失敗、沒有基準可以判斷，退化成舊行為
    /// （直接套用 newSessionData）。
    func applyBackgroundTransition(
        chatID: Int64,
        sceneName: String,
        kind: TransitionKind,
        newStateData: Data?,
        newSessionData: Data,
        baselineSessionData: Data?
    ) async
}
