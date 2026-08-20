import Foundation
import Logging
import TGBotTransport
import TGBotAccessControl
import TGBotConversation
import TGBotBackgroundTask

/// 對外統一入口，組裝所有內部模組，提供開發者實際使用的型別與註冊 API。
/// 開發者只會看到、只會 import 到這一個型別，見架構設計文件第 3／13 節。
public final class TGBot: @unchecked Sendable {
    private let configuration: Configuration
    private let apiClient: TelegramAPIClient
    private let updateSource: UpdateSource
    private let accessPolicy: AccessPolicy
    private let engine: ConversationEngine
    private let registry: EngineRegistry
    private let logger: Logger

    private var commandDescriptions: [(name: String, description: String)] = []

    public init(
        configuration: Configuration,
        updateSource: UpdateSource? = nil,
        stateStore: StateStore? = nil,
        scheduler: BackgroundTaskScheduling? = nil,
        apiClient: TelegramAPIClient? = nil
    ) {
        self.configuration = configuration

        var logger = Logger(label: "TGBot")
        logger.logLevel = configuration.logLevel
        self.logger = logger

        let apiClient = apiClient ?? URLSessionTelegramAPIClient(token: configuration.token, logger: logger)
        self.apiClient = apiClient
        self.updateSource = updateSource ?? PollingUpdateSource(apiClient: apiClient, logger: logger)
        self.accessPolicy = configuration.allowList
        let store = stateStore ?? InMemoryStateStore()
        let taskScheduler = scheduler ?? BackgroundTaskManager()
        let registry = EngineRegistry()
        self.registry = registry
        self.engine = ConversationEngine(
            stateStore: store,
            apiClient: apiClient,
            scheduler: taskScheduler,
            logger: logger,
            registry: registry
        )
    }

    /// 註冊一個 scene。trigger 決定要不要開放使用者直接用指令進入（bootstrapping，
    /// 見架構設計文件第 9 節）——`nil` 代表這個 scene 只打算被別的 scene 用
    /// `Transition.interrupt(with:)` 中斷帶進來，不開放使用者自己打指令啟動（例如
    /// 一個「填地址」的子流程，通常不需要讓使用者能繞過主流程直接打 `/address` 進來）。
    /// 不管有沒有給 trigger，scene 都會被正確註冊、能被中斷帶進來使用；
    /// 只有給了 trigger，才會額外開放指令觸發、才有機會同步進指令選單。
    ///
    /// 同步呼叫（不需要 await）：寫進的是鎖保護的 EngineRegistry，不經過 actor，
    /// 保證在 run() 開始輪詢前一定已經註冊完成。
    ///
    /// description 有給的話，觸發這個 scene 的指令一併會同步進 Telegram 的
    /// setMyCommands 選單（見第 8.1 節）——原本這裡沒有這個參數，只有 onCommand(...)
    /// 才會被同步，導致用 register(_:trigger:) 開始的流程指令（例如 /profile）
    /// 永遠不會出現在 Telegram 的「/」選單裡，即使指令本身完全能正常觸發也一樣。
    /// 這是拿 Example 實機測試才發現的落差，文件審查跟單元測試都沒抓到。
    /// description 沒有搭配 trigger 的話會被忽略——沒有指令名稱可以掛，同步不了選單。
    public func register<State: ConversationState, Session: Codable & Sendable>(
        _ scene: Scene<State, Session>,
        trigger: Trigger? = nil,
        description: String? = nil
    ) {
        switch trigger {
        case .command(let name):
            registry.registerScene(scene, commandTrigger: name)
            if let description {
                commandDescriptions.append((name: name, description: description))
            }
        case nil:
            registry.registerScene(scene, commandTrigger: nil)
        }
    }

    /// 全域指令，description 會在 run() 時自動同步至 Telegram 的 setMyCommands（見第 8.1 節）。
    public func onCommand(
        _ name: String,
        description: String? = nil,
        handler: @escaping @Sendable (GlobalContext) async throws -> Void
    ) {
        if let description {
            commandDescriptions.append((name: name, description: description))
        }
        registry.registerCommand(name, handler: handler)
    }

    /// 未命中任何 scene／指令時的 fallback，不設定則靜默忽略。見架構設計文件第 9 節。
    public func onUnhandled(_ handler: @escaping @Sendable (GlobalContext) async throws -> Void) {
        registry.setUnhandledHandler(handler)
    }

    /// Scene handler 拋出未接住的錯誤時，記 log 之外，額外呼叫這個 hook。見架構設計文件 6.5 節。
    /// 跟 onUnhandled(...) 走同一套「同步寫進鎖保護的 EngineRegistry」模式，保證在 run()
    /// 開始輪詢前一定已經註冊完成。
    public func onError(_ handler: @escaping @Sendable (GlobalContext, Error) async throws -> Void) {
        registry.setErrorHandler(handler)
    }

    /// 啟動：依 configuration 決定用哪種 UpdateSource，並自動呼叫 setMyCommands 同步指令選單。
    /// 見架構設計文件第 8.1／9 節。
    public func run() async throws {
        if !commandDescriptions.isEmpty {
            try await apiClient.setMyCommands(commandDescriptions)
        }
        try await updateSource.start { [engine, accessPolicy, logger, apiClient, configuration] update in
            guard accessPolicy.isAllowed(userID: update.userID, chatID: update.chatID) else {
                logger.debug("rejected unauthorized update from chat \(update.chatID)")
                // US-4：白名單擋下的請求要收到「明確拒絕回覆」，不是靜默忽略——這是需求書
                // 明文寫的行為，之前這裡只記了 log、從沒真的回過訊息，是文件對照才發現的落差。
                // 用 try? 是因為就算這次回覆失敗（例如使用者封鎖了 bot），也不該讓輪詢迴圈掛掉。
                try? await apiClient.sendMessage(
                    chatID: update.chatID,
                    text: configuration.unauthorizedMessage(update.userID, update.chatID)
                )
                return
            }
            await engine.dispatch(update: update)
        }
    }
}
