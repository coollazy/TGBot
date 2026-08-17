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
    private let stateStore: StateStore
    private let engine: ConversationEngine
    private let scheduler: BackgroundTaskScheduling
    private let logger: Logger

    private var commandDescriptions: [(name: String, description: String)] = []
    private var errorHandler: (@Sendable (GlobalContext, Error) async throws -> Void)?

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
        self.stateStore = store
        self.engine = ConversationEngine(stateStore: store)
        self.scheduler = scheduler ?? BackgroundTaskManager()
    }

    /// 註冊一個 scene，trigger 決定何時進入（bootstrapping）。見架構設計文件第 9 節。
    public func register<State: ConversationState, Session: Codable & Sendable>(
        _ scene: Scene<State, Session>,
        trigger: Trigger
    ) {
        // TODO: 把 (trigger -> scene) 的對應關係記下來，交給 ConversationEngine.dispatch 使用
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
        // TODO: 把 (name -> handler) 的對應關係記下來，交給 ConversationEngine.dispatch 使用
    }

    /// 未命中任何 scene／指令時的 fallback，不設定則靜默忽略。見架構設計文件第 9 節。
    public func onUnhandled(_ handler: @escaping @Sendable (GlobalContext) async throws -> Void) {
        // TODO
    }

    /// Scene handler 拋出未接住的錯誤時，記 log + 自動 rollback 之外，額外呼叫這個 hook。
    /// 見架構設計文件 6.5 節。
    public func onError(_ handler: @escaping @Sendable (GlobalContext, Error) async throws -> Void) {
        errorHandler = handler
    }

    /// 啟動：依 configuration 決定用哪種 UpdateSource，並自動呼叫 setMyCommands 同步指令選單。
    /// 見架構設計文件第 8.1／9 節。
    public func run() async throws {
        try await apiClient.setMyCommands(commandDescriptions)
        try await updateSource.start { [engine] update in
            await engine.dispatch(update: update)
        }
    }
}
