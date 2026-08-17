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
                apiClient: apiClient,
                engine: self,
                logger: logger
            )
        }

        do {
            if let commandName = update.commandName, let handler = registry.commandHandler(for: commandName) {
                try await handler(makeGlobalContext(text: update.text, callbackData: nil))
                return
            }

            var record = await stateStore.load(chatID: update.chatID)

            let sceneToRun: AnyScene?
            if let activeSceneName = record.activeScene, let scene = registry.scene(named: activeSceneName) {
                sceneToRun = scene
            } else if let commandName = update.commandName, let scene = registry.scene(forTrigger: commandName) {
                sceneToRun = scene
                record.activeScene = scene.name
                record.currentStateData = nil // 全新進入，交給 AnyScene 用 scene.initial
            } else {
                sceneToRun = nil
            }

            guard let scene = sceneToRun else {
                if let unhandledHandler = registry.unhandledHandlerIfAny() {
                    try await unhandledHandler(makeGlobalContext(text: update.text, callbackData: update.callbackData))
                }
                return
            }

            let result = try await scene.resume(
                update: update,
                savedState: record.currentStateData,
                savedSession: record.sessionData,
                dependencies: dependencies
            )

            switch result.transition {
            case .moved, .stayed, .rolledBack:
                // TODO: rollback 需要歷史棧配合，下一階段實作；目前先當作停留處理
                record.activeScene = scene.name
                record.currentStateData = result.newState
                record.sessionData = result.newSession
                await stateStore.save(chatID: update.chatID, record)
            case .ended:
                record.reset()
                await stateStore.save(chatID: update.chatID, record)
            case .interrupted:
                fatalError("dispatch: interrupt 尚未實作")
            }
        } catch {
            logger.error("scene resume failed for chat \(update.chatID): \(error)")
            // TODO: 6.5 節完整的「記 log + 自動 rollback + 可選 onError hook」，這裡先只記 log
        }
    }
}
