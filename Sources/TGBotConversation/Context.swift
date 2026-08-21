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
        photo: IncomingFile? = nil,
        document: IncomingFile? = nil,
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
            photo: photo,
            document: document,
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
        // 任務啟動當下（同步、Task {} 之前）拍一張 session 快照：在任務真的完成、
        // onComplete 閉包被呼叫之前，沒有其他東西會動這個 self.session（唯一會動它的
        // 就是 onComplete 閉包本身），所以這是可靠的「任務啟動當下」基準。用來讓
        // applyBackgroundTransition 判斷：完成時資料庫裡的 session 如果還是這份快照，
        // 代表使用者沒有在任務執行期間同時編輯過，可以放心套用任務算出來的結果；如果
        // 不一樣，代表使用者透過正常 dispatch() 又走了幾步、session 也被改過，那份較新
        // 的 session 不該被任務啟動當下的舊快照蓋掉。try?：這個函式本身簽名不丟錯，
        // 編碼失敗（極端邊界）就視為「沒有基準可以判斷」，不擋任務啟動。
        let baselineSessionData = try? canonicalJSONEncoder().encode(session)
        Task {
            // 把型別安全的 onComplete 用型別擦除包起來，存進這個 chat 的 pendingCompletions（6.2 節）。
            //
            // 這裡刻意強引用 self（不是 [weak self]）：原本用 weak 是想避免 self（Context）
            // 跟 engine 互相持有造成的循環引用，但這個閉包本來就是「等真的任務完成才會被呼叫」，
            // 如果排程器是真的異步完成（例如真正的 BackgroundTaskManager，或這裡改用的
            // ManualScheduler 測試），呼叫這個 startBackgroundJob 的那個 Task 執行完就結束了，
            // 沒有其他東西強引用 self，self 會在任務真的完成之前就被釋放，導致這個
            // guard let self 直接失敗、onComplete 整個靜默不會被呼叫——連「通知一定送達」
            // 這個背景任務最基本的承諾都會破功。是這次新加的、用會真的延遲觸發完成的排程器
            // 測試才抓到的，之前的測試全部用「一啟動就同步完成」的假排程器，剛好都繞過了
            // 這個窗口，沒有真的測到延遲完成的情況。循環引用的代價（只有在任務完成通知
            // 永遠沒被送達的情況下才會真的洩漏）遠比「通知靜默消失」這個核心保證破功要小，
            // 所以選擇強引用。
            await engine.registerPendingCompletion(chatID: chatID, taskID: id) { [self] result in
                if let transition = try await onComplete(result, id, self) {
                    // 在這裡（還是具體的 State/Session 型別）編碼成引擎看得懂的擦除後格式，
                    // 呼叫 applyBackgroundTransition 套用回對話狀態——只有原本的 scene 仍然
                    // active 時才會真的生效，見 ConversationEngineHandle 的說明。
                    let encoder = canonicalJSONEncoder()
                    let kind: TransitionKind
                    let newStateData: Data?
                    switch transition {
                    case .transition(to: let newState):
                        kind = .moved
                        newStateData = try encoder.encode(newState)
                    case .stay:
                        kind = .stayed
                        newStateData = nil
                    case .rollback:
                        kind = .rolledBack
                        newStateData = nil
                    case .end:
                        kind = .ended
                        newStateData = nil
                    case .endWithResult:
                        // 這條通道（背景任務完成觸發的 transition）本來就不支援 interrupt／
                        // 結果交還語意，跟既有的 .interrupt case 一樣，結果資料沒有地方可以
                        // 送達，安靜忽略，行為等同不帶 payload 的 .end。
                        kind = .ended
                        newStateData = nil
                    case .interrupt, .interruptWithReturn:
                        // onReturn（如果有的話）一併被忽略，理由同上。
                        kind = .interrupted
                        newStateData = nil
                    }
                    let newSessionData = try encoder.encode(self.session)
                    await engine.applyBackgroundTransition(
                        chatID: self.chatID,
                        sceneName: self.sceneName,
                        kind: kind,
                        newStateData: newStateData,
                        newSessionData: newSessionData,
                        baselineSessionData: baselineSessionData
                    )
                }
            }
            // 交給排程器的是不帶型別的版本，排程器完成後只需要「通知引擎去處理」
            await scheduler.start(chatID: chatID, taskID: id, work: work) { [engine, chatID] result in
                await engine.deliverBackgroundJobResult(chatID: chatID, taskID: id, result: result)
            }
        }
    }
}
