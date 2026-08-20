import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// `AnyScene(_:initialSession:)`：父流程用 `.interrupt(with:)` 中斷帶進子流程時，
/// 順便把自己現在的資料傳進去子流程的起始 session——對應「設定子流程要顯示父流程已經
/// 收集的資料，但被中斷帶進去的子流程永遠是全新空的 session」這個設計討論。跟
/// `.interrupt(with:onReturn:)`（子流程結束時把結果帶「回」父流程）方向相反，互不影響，
/// 可以同時用。
@Suite("AnyScene initialSession")
struct InitialSessionTests {
    enum MainState: ConversationState { case main }
    enum SubState: ConversationState { case sub }
    struct SubSession: Codable, Sendable {
        var seed: String
    }

    final class RecordingAPIClient: TelegramAPIClient, @unchecked Sendable {
        private(set) var sentMessages: [(chatID: Int64, text: String)] = []
        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
            sentMessages.append((chatID, text))
        }
        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
        func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {}
        func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws {}
        func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws {}
    }

    struct NoOpScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
    }

    func makeEngine(_ apiClient: TelegramAPIClient) -> (ConversationEngine, EngineRegistry) {
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )
        return (engine, registry)
    }

    @Test(".interrupt(with: AnyScene(sub, initialSession:)) hands the parent-provided value to the sub-flow's session (inside)")
    func initialSessionOverrideReachesSubFlow() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, SubSession>(name: "initsession-sub", initial: .sub, initialSession: SubSession(seed: "default"))
        sub.on(.sub) { ctx in
            try await ctx.reply("seed: \(ctx.session.seed)")
            return .end
        }

        let main = Scene<MainState, EmptySession>(name: "initsession-main", initial: .main)
        main.on(.main) { ctx in
            return .interrupt(with: AnyScene(sub, initialSession: SubSession(seed: "from-parent")))
        }
        registry.registerScene(main, commandTrigger: "initsession-main")
        registry.registerScene(sub, commandTrigger: "initsession-sub-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/initsession-main", commandName: "initsession-main"))

        #expect(apiClient.sentMessages.map(\.text) == ["seed: from-parent"])
    }

    @Test("plain AnyScene(sub) with no initialSession keeps using the sub-flow's own initialSession (outside: regression)")
    func noInitialSessionOverrideKeepsDefault() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, SubSession>(name: "initsession-sub2", initial: .sub, initialSession: SubSession(seed: "default"))
        sub.on(.sub) { ctx in
            try await ctx.reply("seed: \(ctx.session.seed)")
            return .end
        }

        let main = Scene<MainState, EmptySession>(name: "initsession-main2", initial: .main)
        main.on(.main) { ctx in
            return .interrupt(with: AnyScene(sub)) // 沒給 initialSession
        }
        registry.registerScene(main, commandTrigger: "initsession-main2")
        registry.registerScene(sub, commandTrigger: "initsession-sub2-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/initsession-main2", commandName: "initsession-main2"))

        #expect(apiClient.sentMessages.map(\.text) == ["seed: default"])
    }

    @Test("onEnter combined with initialSession: the sub-flow's entry prompt can read the parent-provided data (inside: settings-like scenario)")
    func onEnterCanReadInitialSessionOverride() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, SubSession>(name: "initsession-sub3", initial: .sub, initialSession: SubSession(seed: "default"))
        sub.onEnter(.sub) { ctx in
            try await ctx.reply("onEnter saw seed: \(ctx.session.seed)")
            return .stay
        }
        sub.on(.sub) { ctx in
            try await ctx.reply("on saw seed: \(ctx.session.seed)")
            return .end
        }

        let main = Scene<MainState, EmptySession>(name: "initsession-main3", initial: .main)
        main.on(.main) { ctx in
            return .interrupt(with: AnyScene(sub, initialSession: SubSession(seed: "settings-data")))
        }
        registry.registerScene(main, commandTrigger: "initsession-main3")
        registry.registerScene(sub, commandTrigger: "initsession-sub3-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/initsession-main3", commandName: "initsession-main3"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "anything"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "onEnter saw seed: settings-data",
            "on saw seed: settings-data",
        ])
    }
}
