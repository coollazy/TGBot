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
        scheduler: BackgroundTaskScheduling? = nil
    ) {
        self.configuration = configuration

        var logger = Logger(label: "TGBot")
        logger.logLevel = configuration.logLevel
        self.logger = logger

        let apiClient = URLSessionTelegramAPIClient(token: configuration.token, logger: logger)
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

    /// 註冊一個 scene，trigger 決定何時進入（bootstrapping）。見架構設計文件第 9 節。
    /// 同步呼叫（不需要 await）：寫進的是鎖保護的 EngineRegistry，不經過 actor，
    /// 保證在 run() 開始輪詢前一定已經註冊完成。
    public func register<State: ConversationState, Session: Codable & Sendable>(
        _ scene: Scene<State, Session>,
        trigger: Trigger
    ) {
        switch trigger {
        case .command(let name):
            registry.registerScene(scene, commandTrigger: name)
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

    /// Scene handler 拋出未接住的錯誤時，記 log + 自動 rollback 之外，額外呼叫這個 hook。
    /// 見架構設計文件 6.5 節。TODO：與 ConversationEngine 的錯誤處理路徑接上，下一階段實作。
    public func onError(_ handler: @escaping @Sendable (GlobalContext, Error) async throws -> Void) {
        // TODO
    }

    /// 啟動：依 configuration 決定用哪種 UpdateSource，並自動呼叫 setMyCommands 同步指令選單。
    /// 見架構設計文件第 8.1／9 節。
    public func run() async throws {
        if !commandDescriptions.isEmpty {
            try await apiClient.setMyCommands(commandDescriptions)
        }
        try await updateSource.start { [engine, accessPolicy, logger] update in
            guard accessPolicy.isAllowed(userID: update.userID, chatID: update.chatID) else {
                logger.debug("rejected unauthorized update from chat \(update.chatID)")
                // TODO: 回覆 configuration.unauthorizedMessage，見架構設計文件第 5 節
                return
            }
            await engine.dispatch(update: update)
        }
    }
}
