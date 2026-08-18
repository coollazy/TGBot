import Foundation
import Logging
import TGBotTransport

/// 開發者在 scene 的 state handler 裡實際拿到、實際會打的型別，繼承 GlobalContext
/// 再加上跟具體 State/Session 綁定的能力。見架構設計文件 6.1 節。
public final class Context<State: ConversationState, Session: Codable & Sendable>: GlobalContext, @unchecked Sendable {
    public var session: Session

    let scheduler: BackgroundTaskScheduling
    let sceneName: String

    init(
        chatID: Int64,
        userID: Int64?,
        text: String?,
        callbackData: String?,
        messageID: Int64? = nil,
        session: Session,
        sceneName: String,
        apiClient: TelegramAPIClient,
        scheduler: BackgroundTaskScheduling,
        engine: ConversationEngineHandle,
        logger: Logger
    ) {
        self.session = session
        self.sceneName = sceneName
        self.scheduler = scheduler
        super.init(
            chatID: chatID,
            userID: userID,
            text: text,
            callbackData: callbackData,
            messageID: messageID,
            apiClient: apiClient,
            engine: engine,
            logger: logger
        )
    }

    /// 查詢背景任務目前的狀態（對應 US-3：長任務執行期間，讓使用者能查詢「目前在處理什麼、
    /// 進度如何」）。任務不存在（例如 id 打錯、或已經完成很久被排程器清掉）回傳 nil，
    /// 由開發者決定要怎麼回覆使用者，框架不強加特定的「找不到」訊息格式。
    public func backgroundJobStatus(id: String) async -> JobStatus? {
        await scheduler.status(chatID: chatID, taskID: id)
    }

    /// 啟動背景任務。taskID 讓開發者在多個背景任務並存時能辨識是哪一個完成了（對應 US-6）；
    /// onComplete 回傳值可選是否要順便觸發 transition，回傳 nil 代表只做通知，不改變狀態。
    /// 見架構設計文件 6.1／7／7.1 節：通知一定送達，觸發 transition 則要求原本的 scene 仍存在。
    public func startBackgroundJob(
        id: String,
        work: @escaping @Sendable (JobProgress) async throws -> Void,
        onComplete: @escaping @Sendable (JobResult, String, Context<State, Session>) async throws -> Transition<State>?
    ) {
        Task {
            // 把型別安全的 onComplete 用型別擦除包起來，存進這個 chat 的 pendingCompletions（6.2 節）
            await engine.registerPendingCompletion(chatID: chatID, taskID: id) { [weak self] result in
                guard let self else { return }
                if let transition = try await onComplete(result, id, self) {
                    // TODO: 實作把 transition 套用回這個 scene 的邏輯，見架構設計文件 7.1 節
                    _ = transition
                }
            }
            // 交給排程器的是不帶型別的版本，排程器完成後只需要「通知引擎去處理」
            await scheduler.start(chatID: chatID, taskID: id, work: work) { [engine, chatID] result in
                await engine.deliverBackgroundJobResult(chatID: chatID, taskID: id, result: result)
            }
        }
    }
}
