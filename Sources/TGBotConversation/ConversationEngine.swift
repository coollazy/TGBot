import Foundation
import TGBotTransport
import Logging

/// 每個 chat 的對話狀態透過這個 actor 序列化處理，確保同一 chat 的事件依序執行、
/// 不同 chat 天然並發。見架構設計文件 6.4 節。
///
/// 已知簡化（垂直切片階段，非最終設計）：目前是「一個 actor 處理所有 chat」，
/// 這保證了同一 chat 的事件依序執行（正確性沒問題），但也讓不同 chat 的 dispatch
/// 彼此排隊、無法真正平行，跟架構文件「跨 chat 無限並發」的目標有落差。
/// 要做到真正的 per-chat 並發，需要把這個 actor 拆成「依 chatID 分派的多個 actor」
/// （例如一個 actor pool，或每個 chatID 動態建立一個 actor），留待下一階段優化。
public actor ConversationEngine: ConversationEngineHandle {
    private let stateStore: StateStore
    private let apiClient: TelegramAPIClient
    private let scheduler: BackgroundTaskScheduling
    private let logger: Logger
    private let registry: EngineRegistry

    // 背景任務的待處理完成回呼，刻意存在這裡（純記憶體）而不是 ChatConversationRecord 裡，
    // 見 ChatConversationRecord.swift 的說明：閉包無法 Codable 化，且要獨立於「對話流程本身」
    // 之外，確保 .end／resetConversation() 不會連帶清掉它（US-5／US-6）。
    private var pendingCompletions: [Int64: [String: @Sendable (JobResult) async throws -> Void]] = [:]

    public init(
        stateStore: StateStore,
        apiClient: TelegramAPIClient,
        scheduler: BackgroundTaskScheduling,
        logger: Logger,
        registry: EngineRegistry
    ) {
        self.stateStore = stateStore
        self.apiClient = apiClient
        self.scheduler = scheduler
        self.logger = logger
        self.registry = registry
    }

    // MARK: - ConversationEngineHandle

    public func resetConversation(chatID: Int64) async {
        var record = await stateStore.load(chatID: chatID)
        record.reset()
        await stateStore.save(chatID: chatID, record)
        // pendingCompletions 刻意不清，見上方欄位說明
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

    package func applyBackgroundTransition(
        chatID: Int64,
        sceneName: String,
        kind: TransitionKind,
        newStateData: Data?,
        newSessionData: Data
    ) async {
        var record = await stateStore.load(chatID: chatID)
        guard record.activeScene == sceneName else {
            // 使用者可能在背景任務跑的期間已經 /cancel、或觸發別的全域指令切走了，這種情況下
            // 不該把已經跑完的舊流程結果硬套回目前的對話狀態——通知一定已經送達（見
            // deliverBackgroundJobResult／startBackgroundJob 的 reply 那條路徑），這裡只影響
            // 「要不要順便觸發狀態轉移」，跳過不算漏做事。
            logger.debug("applyBackgroundTransition: scene \(sceneName) is no longer active for chat \(chatID), skipping")
            return
        }
        switch kind {
        case .moved:
            record.currentStateData = newStateData
            record.sessionData = newSessionData
            await stateStore.save(chatID: chatID, record)
        case .stayed, .rolledBack:
            // Context 本身沒有保存「目前的 state」（開發者在 onComplete 裡拿到的 Context 只
            // 帶 session），所以這裡沒有東西可以重新編碼進 currentStateData，維持原樣不動；
            // 只更新 session（開發者可能在 onComplete 裡改了 ctx.session）。
            // 已知取捨：如果使用者在背景任務執行期間、於同一個 scene 內又往下走了幾步、
            // session 也跟著被改過，這裡會用背景任務啟動當下那份舊的 session 覆蓋掉——
            // 這個時間窗口的資料競爭目前沒有處理，留待有實際需求再評估怎麼做（例如欄位級合併）。
            record.sessionData = newSessionData
            await stateStore.save(chatID: chatID, record)
        case .ended:
            record.reset()
            await stateStore.save(chatID: chatID, record)
        case .interrupted:
            // 背景任務完成時觸發 interrupt 語意不明確（scene 棧的操作預期只發生在正常 dispatch
            // 路徑），現在不支援，安靜忽略＋記 log，不要推進一個沒有配套流程能接住的狀態。
            logger.debug("applyBackgroundTransition: .interrupted from a background job completion is not supported, ignoring")
        }
    }

    // MARK: - Dispatch（核心）

    /// 把一個 Update 分派給目前 chat 對應的 scene handler，或全域指令、或 fallback。
    /// 見架構設計文件第 9 節：全域指令優先於 active scene（例如 /cancel 要能隨時打斷），
    /// 沒有 active scene 時才看指令是否是某個 scene 的 trigger。
    public func dispatch(update: Update) async {
        let dependencies = SceneDependencies(
            apiClient: apiClient,
            scheduler: scheduler,
            engine: self,
            logger: logger
        )

        func makeGlobalContext(text: String?, callbackData: String?) -> GlobalContext {
            GlobalContext(
                chatID: update.chatID,
                userID: update.userID,
                text: text,
                callbackData: callbackData,
                messageID: update.messageID,
                apiClient: apiClient,
                engine: self,
                logger: logger
            )
        }

        // Telegram 規定收到 callback_query 要確認收到，不然按鈕在使用者端會一直卡在
        // 「處理中」的狀態——這件事開發者不需要知道也不需要自己做，框架在分派前先處理掉。
        // 用 try? 是因為就算確認失敗（例如按鈕太舊、query 已過期），也不該讓整個
        // dispatch 因此中斷；正常的 handler 邏輯還是要照跑。
        if let callbackQueryID = update.callbackQueryID {
            try? await apiClient.answerCallbackQuery(callbackQueryID: callbackQueryID)

            // 同時把按鈕所在那則舊訊息的 inline keyboard 拿掉，避免使用者事後回頭誤點
            // 已經處理過的按鈕——那個點擊還是會產生合法的 callback_query，但會被目前的
            // 對話狀態誤判成別的意思，跳出文不對題的回覆。跟上面一樣用 try?，失敗
            // （例如訊息太舊、已經被使用者刪除）不該擋住正常的 handler 邏輯繼續跑。
            if let messageID = update.messageID {
                try? await apiClient.editMessageReplyMarkup(chatID: update.chatID, messageID: messageID)
            }
        }

        logger.debug("dispatch: chat=\(update.chatID) command=\(update.commandName ?? "nil") text=\(update.text ?? "nil") callbackData=\(update.callbackData ?? "nil") callbackQueryID=\(update.callbackQueryID ?? "nil")")

        do {
            if let commandName = update.commandName, let handler = registry.commandHandler(for: commandName) {
                try await handler(makeGlobalContext(text: update.text, callbackData: nil))
                return
            }

            var record = await stateStore.load(chatID: update.chatID)
            logger.debug("dispatch: chat=\(update.chatID) loaded record.activeScene=\(record.activeScene ?? "nil")")

            let sceneToRun: AnyScene?
            if let activeSceneName = record.activeScene, let scene = registry.scene(named: activeSceneName) {
                sceneToRun = scene
            } else if let commandName = update.commandName, let scene = registry.scene(forTrigger: commandName) {
                sceneToRun = scene
                record.activeScene = scene.name
                record.currentStateData = nil // 全新進入，交給 AnyScene 用 scene.initial
                record.stateHistory = [] // 全新進入，不該帶著上一段（可能是別的 scene）的歷史
            } else {
                sceneToRun = nil
            }

            guard var scene = sceneToRun else {
                logger.debug("dispatch: chat=\(update.chatID) no scene matched, unhandledHandler=\(registry.unhandledHandlerIfAny() != nil)")
                if let unhandledHandler = registry.unhandledHandlerIfAny() {
                    try await unhandledHandler(makeGlobalContext(text: update.text, callbackData: update.callbackData))
                }
                return
            }

            // 用迴圈而非單次呼叫：.interrupted 時要「立刻」把同一筆 update 餵給剛切換進去
            // 的新 scene 執行它自己的 initial state handler，跟頂層指令觸發 scene 進入時的
            // 行為一致（進入當下就看得到第一句話，不用使用者多送一句什麼都沒意義的訊息
            // 才會有反應）。.ended 時則不會這樣接著跑——被恢復的流程要等使用者真的送下一句
            // 新的話才處理，剛剛結束子流程那句話不該被誤當成也是說給被恢復的流程聽的。
            while true {
                logger.debug("dispatch: chat=\(update.chatID) running scene=\(scene.name)")

                let result = try await scene.resume(
                    update: update,
                    savedState: record.currentStateData,
                    savedSession: record.sessionData,
                    stateHistory: record.stateHistory,
                    dependencies: dependencies
                )

                logger.debug("dispatch: chat=\(update.chatID) scene=\(scene.name) transition=\(result.transition)")

                switch result.transition {
                case .moved, .stayed, .rolledBack:
                    record.activeScene = scene.name
                    record.currentStateData = result.newState
                    record.sessionData = result.newSession
                    record.stateHistory = result.newHistory
                    await stateStore.save(chatID: update.chatID, record)
                    return
                case .ended:
                    if let suspended = record.sceneStack.popLast() {
                        // 被中斷的流程還在等——原地恢復它暫停當下的 state/session，讓下一輪
                        // 使用者輸入直接接著原本被中斷的地方繼續跑。
                        // 已知限制（最小版本）：暫停時的 stateHistory 沒有一起存，恢復後這個
                        // scene 的 rollback 歷史是空的；sessionData 也不會清空以外的欄位重置，
                        // 只還原 activeScene／currentStateData／sessionData 這三項。
                        record.activeScene = suspended.scene.name
                        record.currentStateData = suspended.savedState
                        record.sessionData = suspended.savedSession
                        record.stateHistory = []
                        await stateStore.save(chatID: update.chatID, record)

                        // 選配：這個 state 有沒有註冊 onResume 完全交給開發者決定——使用者
                        // 不知道什麼是「scene」、什麼是「子流程」，框架自己硬塞一句通用訊息
                        // 對使用者來說毫無意義，所以框架只保證「恢復這件事發生時會呼叫這個
                        // hook」，實際要不要講話、講什麼話，開發者自己決定。沒註冊就靜默，
                        // 是實機測試發現「岔出去再回來，使用者完全不知道發生什麼事」才補上的。
                        // 用 try? 是因為這個 hook 本身丟錯，不該讓已經完成的恢復動作被回滾。
                        try? await suspended.scene.notifyResumed(
                            chatID: update.chatID,
                            userID: update.userID,
                            savedState: suspended.savedState,
                            savedSession: suspended.savedSession,
                            dependencies: dependencies
                        )
                    } else {
                        record.reset()
                        await stateStore.save(chatID: update.chatID, record)
                    }
                    return
                case .interrupted:
                    guard let suspended = result.suspended, let interruptingScene = result.interruptingScene else {
                        logger.error("dispatch: .interrupted transition missing suspended/interruptingScene payload for chat \(update.chatID)")
                        return
                    }
                    record.sceneStack.append(suspended)
                    record.activeScene = interruptingScene.name
                    record.currentStateData = nil // 新流程從自己的 initial 開始
                    record.sessionData = Data()
                    record.stateHistory = []
                    scene = interruptingScene
                    // 不 return、不存檔——繼續迴圈，立刻用同一筆 update 跑新 scene；
                    // 存檔會在新 scene 這一輪真正處理完（.moved／.stayed／.ended／...）時才做。
                }
            }
        } catch {
            logger.error("scene resume failed for chat \(update.chatID): \(error)")
            // TODO: 6.5 節「handler 拋錯時自動 rollback」還沒做——狀態歷史棧本身已經有了
            // （見 Transition.rollback／AnyScene），但那是「開發者自己決定要退回」的路徑；
            // 這裡是「handler 拋出未接住的例外」，要不要自動幫開發者退回上一步、還是維持
            // 現狀讓開發者自己在 onError 裡決定，是另一個設計取捨，留待有實際需求再做。
            // onError hook 已經接上：開發者有註冊的話，這裡額外通知，讓他們能自己決定要不要
            // 回訊息給使用者、要不要額外上報；用 try? 是因為 hook 本身如果又拋錯，不該讓
            // dispatch 整個掛掉——原本的錯誤已經記過 log 了。
            if let errorHandler = registry.errorHandlerIfAny() {
                try? await errorHandler(makeGlobalContext(text: update.text, callbackData: update.callbackData), error)
            }
        }
    }
}
