import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// ConversationEngine.dispatch 的路由優先順序（見架構設計文件第 9 節）：
/// 全域指令 > 目前 active scene > scene 的 trigger（bootstrapping）> onUnhandled fallback。
/// 這條優先序列先前完全沒有測試守著——尤其「全域指令要能打斷進行中的 scene」
/// （對應 US-5：/cancel 要能隨時打斷）是最容易不小心被 active scene 攔截掉的一條路徑。
@Suite("Dispatch priority")
struct DispatchPriorityTests {
    enum State: ConversationState { case waiting }

    final class RecordingAPIClient: TelegramAPIClient, @unchecked Sendable {
        private(set) var sentMessages: [(chatID: Int64, text: String)] = []
        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
            sentMessages.append((chatID, text))
        }
        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
        func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {}
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

    @Test("a global command interrupts an in-progress scene instead of being swallowed by it")
    func globalCommandInterruptsActiveScene() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        // 一個永遠停在原地、把每個文字都吃掉的 scene（模擬使用者卡在流程中）
        let waiting = Scene<State, EmptySession>(name: "waiting", initial: .waiting)
        waiting.on(.waiting) { ctx in
            try await ctx.reply("scene got: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(waiting, commandTrigger: "wait")
        registry.registerCommand("cancel") { ctx in
            await ctx.resetConversation()
            try await ctx.reply("cancelled")
        }

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/wait", commandName: "wait"))
        // 使用者這時還在 waiting scene 裡，但打了 /cancel——應該被全域指令接住，
        // 不能被 waiting scene 的 handler 當成一般文字處理掉
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "/cancel", commandName: "cancel"))

        #expect(apiClient.sentMessages.count == 2)
        #expect(apiClient.sentMessages[0].text == "scene got: /wait")
        #expect(apiClient.sentMessages[1].text == "cancelled")

        // 而且對話真的被清空了：再傳一句無關的話，不會又被 waiting scene 接住
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "still here?"))
        #expect(apiClient.sentMessages.count == 2)
    }

    @Test("onUnhandled fires when nothing matches: no active scene, no trigger, no command")
    func unhandledFallbackFires() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        registry.setUnhandledHandler { ctx in
            try await ctx.reply("didn't understand: \(ctx.text ?? "")")
        }

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "random gibberish"))

        #expect(apiClient.sentMessages.count == 1)
        #expect(apiClient.sentMessages[0].text == "didn't understand: random gibberish")
    }

    @Test("without onUnhandled registered, an unmatched update is silently dropped (no crash, no reply)")
    func noUnhandledHandlerMeansSilence() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, _) = makeEngine(apiClient)

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "random gibberish"))

        #expect(apiClient.sentMessages.isEmpty)
    }
}
