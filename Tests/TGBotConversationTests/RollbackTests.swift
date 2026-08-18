import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// US-2：錯誤發生時退回先前的步驟重試，不是原地重試（那是 .stay 已經做到的事）、
/// 也不是回到最開始。之前 ChatConversationRecord.stateHistory 這個欄位存在但從沒被
/// 寫入或讀取過，Transition.rollback 現在等同 .stay——這裡驗證真的退回「上一步」。
@Suite("Rollback / state history")
struct RollbackTests {
    enum State: ConversationState {
        case step1, step2, step3
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

    struct NoOpScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
    }

    /// 每個 state 的 handler 收到 "back" 就 .rollback，其他文字就照 step1→2→3 往下走。
    func makeScene() -> Scene<State, EmptySession> {
        let scene = Scene<State, EmptySession>(name: "flow", initial: .step1)
        scene.on(.step1) { ctx in
            if ctx.text == "back" { return .rollback }
            try await ctx.reply("in step1, moving to step2")
            return .transition(to: .step2)
        }
        scene.on(.step2) { ctx in
            if ctx.text == "back" { return .rollback }
            try await ctx.reply("in step2, moving to step3")
            return .transition(to: .step3)
        }
        scene.on(.step3) { ctx in
            if ctx.text == "back" { return .rollback }
            try await ctx.reply("in step3")
            return .stay
        }
        return scene
    }

    @Test("rollback returns to the immediately-preceding step, not the very first one (inside)")
    func rollbackReturnsToPreviousStep() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        registry.registerScene(makeScene(), commandTrigger: "flow")

        // step1 -> step2 -> step3
        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/flow", commandName: "flow"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go"))

        // 現在在 step3，rollback 一次應該回到 step2（不是 step1）
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "back"))
        // 驗證真的回到 step2：傳一句非 "back" 的話，應該命中 step2 的 handler（往 step3 走）
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "go again"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "in step1, moving to step2",
            "in step2, moving to step3",
            "in step2, moving to step3",
        ])
    }

    @Test("rollback with no history left degrades to staying put, no crash (outside: nothing to roll back to)")
    func rollbackWithEmptyHistoryStaysPut() async throws {
        // 用一個獨立的小 scene：進入時（entry 那次 dispatch，input 是觸發指令本身）用 .stay
        // 而不是 .transition，這樣才真的能測到「歷史棧是空的」這個情境——如果進入時就
        // .transition，history 就已經有一筆了，測不到真正空的狀態。
        enum SoloState: ConversationState { case only }
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<SoloState, EmptySession>(name: "solo", initial: .only)
        scene.on(.only) { ctx in
            if ctx.text == "back" { return .rollback }
            try await ctx.reply("still here: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "solo")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/solo", commandName: "solo"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "back"))
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "hello"))

        #expect(apiClient.sentMessages.map(\.text) == ["still here: /solo", "still here: hello"])
    }

    @Test("rolling back all the way through multiple steps returns to each preceding step in order (boundary)")
    func rollbackMultipleTimesWalksBackStepByStep() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        registry.registerScene(makeScene(), commandTrigger: "flow")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/flow", commandName: "flow"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go")) // now step3

        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "back")) // -> step2
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "back")) // -> step1
        // 再退一次：歷史已經空了，應該退化成停在 step1，不是繼續退到不存在的地方
        await engine.dispatch(update: Update(updateID: 5, chatID: 1, text: "back"))

        await engine.dispatch(update: Update(updateID: 6, chatID: 1, text: "go")) // 應該命中 step1

        #expect(apiClient.sentMessages.map(\.text) == [
            "in step1, moving to step2",
            "in step2, moving to step3",
            "in step1, moving to step2",
        ])
    }
}
