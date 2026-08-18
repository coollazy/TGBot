import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 實機測試發現的真實 bug：使用者點 inline 按鈕後畫面「沒反應」，原因是 dispatch
/// 從來沒有呼叫 Telegram 規定必做的 answerCallbackQuery。這裡驗證 dispatch 現在
/// 會自動處理這件事，開發者完全不用知道有這個步驟存在；也驗證純文字 Update
/// 不會被誤觸發（沒有 callbackQueryID 就不該去 ack 任何東西）。
@Suite("callback_query acknowledgement")
struct CallbackQueryAcknowledgementTests {
    enum State: ConversationState { case only }

    final class RecordingAPIClient: TelegramAPIClient, @unchecked Sendable {
        private(set) var sentMessages: [(chatID: Int64, text: String)] = []
        private(set) var acknowledgedCallbackQueryIDs: [String] = []

        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
            sentMessages.append((chatID, text))
        }
        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
        func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {
            acknowledgedCallbackQueryIDs.append(callbackQueryID)
        }
    }

    struct NoOpScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func status(chatID: Int64, taskID: String) -> JobStatus? { nil }
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

    @Test("a callback_query update is automatically acknowledged before the handler even runs (inside)")
    func callbackQueryUpdateIsAcknowledged() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<State, EmptySession>(name: "pick", initial: .only)
        scene.on(.only) { ctx in
            try await ctx.reply("got: \(ctx.callbackData ?? "")")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "pick")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/pick", commandName: "pick"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, callbackData: "go", callbackQueryID: "cb-1"))

        #expect(apiClient.acknowledgedCallbackQueryIDs == ["cb-1"])
        #expect(apiClient.sentMessages[1].text == "got: go")
    }

    @Test("a plain text update never triggers answerCallbackQuery (outside: nothing to acknowledge)")
    func plainTextUpdateDoesNotAcknowledge() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<State, EmptySession>(name: "echo", initial: .only)
        scene.on(.only) { ctx in
            try await ctx.reply("echo: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "echo")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/echo", commandName: "echo"))

        #expect(apiClient.acknowledgedCallbackQueryIDs.isEmpty)
    }

    @Test("acknowledgement failure doesn't block the rest of dispatch (boundary: stale/expired callback query)")
    func acknowledgementFailureDoesNotBlockDispatch() async throws {
        final class FailingAckAPIClient: TelegramAPIClient, @unchecked Sendable {
            private(set) var sentMessages: [(chatID: Int64, text: String)] = []
            struct AckError: Error {}
            func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
                sentMessages.append((chatID, text))
            }
            func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
            func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
            func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {
                throw AckError() // 模擬 Telegram 拒絕（例如 query 太舊）
            }
        }
        let apiClient = FailingAckAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<State, EmptySession>(name: "pick", initial: .only)
        scene.on(.only) { ctx in
            try await ctx.reply("still ran")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "pick")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/pick", commandName: "pick"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, callbackData: "go", callbackQueryID: "cb-stale"))

        // 確認回覆就算 answerCallbackQuery 失敗，handler 還是照跑，不會整個 dispatch 掛掉
        #expect(apiClient.sentMessages.last?.text == "still ran")
    }
}
