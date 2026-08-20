import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// `Scene.onEnter(_:handler:)`：轉移進入一個 state 的當下自動觸發（不需要使用者說話），
/// 對應「`.askAge` 的 handler 卻在處理上一題『名字』的答案」那個設計討論——`onEnter`
/// 負責顯示這個 state 自己的提示，`on` 才負責驗證這個 state 真正要收的答案，兩者拆開，
/// 不再擠在同一個 handler 裡。見 README 的相關章節與這次的計劃文件。
@Suite("Scene.onEnter")
struct OnEnterTests {
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

    @Test("scene bootstrap: initial state's onEnter fires instead of feeding the raw trigger text to on(initial) (inside)")
    func onEnterFiresOnBootstrapInsteadOfRawTrigger() async throws {
        enum State: ConversationState { case start }
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<State, EmptySession>(name: "onenter-bootstrap", initial: .start)
        scene.onEnter(.start) { ctx in
            try await ctx.reply("onEnter: welcome")
            return .stay
        }
        scene.on(.start) { ctx in
            try await ctx.reply("on: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "onenter-bootstrap")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/onenter-bootstrap", commandName: "onenter-bootstrap"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "hello"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "onEnter: welcome",
            "on: hello",
        ])
    }

    @Test(".transition(to:) into a state with onEnter shows its prompt automatically in the same turn (inside)")
    func onEnterFiresOnTransitionSameTurn() async throws {
        enum State: ConversationState { case start, next }
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<State, EmptySession>(name: "onenter-transition", initial: .start)
        scene.on(.start) { ctx in
            return .transition(to: .next)
        }
        scene.onEnter(.next) { ctx in
            try await ctx.reply("onEnter: next state prompt")
            return .stay
        }
        scene.on(.next) { ctx in
            try await ctx.reply("on next: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "onenter-transition")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/onenter-transition", commandName: "onenter-transition"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "answer"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "onEnter: next state prompt",
            "on next: answer",
        ])
    }

    @Test("onEnter returning .transition(to:) instead of .stay cascades without waiting for user input (boundary: pass-through state)")
    func onEnterCascadesWithoutWaiting() async throws {
        enum State: ConversationState { case start, middle, final }
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<State, EmptySession>(name: "onenter-cascade", initial: .start)
        scene.on(.start) { ctx in
            return .transition(to: .middle)
        }
        // .middle 純粹是個判斷/計算用的中繼 state：onEnter 不回話、直接轉移，
        // 不會停下來等使用者輸入。
        scene.onEnter(.middle) { ctx in
            return .transition(to: .final)
        }
        scene.onEnter(.final) { ctx in
            try await ctx.reply("onEnter: final")
            return .stay
        }
        scene.on(.final) { ctx in
            try await ctx.reply("on final: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "onenter-cascade")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/onenter-cascade", commandName: "onenter-cascade"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "answer"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "onEnter: final",
            "on final: answer",
        ])
    }

    @Test(".interrupt(with:) sub-flow's initial state onEnter fires automatically, not the raw triggering Update (inside)")
    func onEnterFiresForInterruptedSubSceneInitial() async throws {
        enum MainState: ConversationState { case main }
        enum SubState: ConversationState { case sub }
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, EmptySession>(name: "onenter-sub", initial: .sub)
        sub.onEnter(.sub) { ctx in
            try await ctx.reply("sub onEnter")
            return .stay
        }
        sub.on(.sub) { ctx in
            try await ctx.reply("sub on: \(ctx.text ?? "")")
            return .end
        }

        let main = Scene<MainState, EmptySession>(name: "onenter-main", initial: .main)
        main.on(.main) { ctx in
            if ctx.text == "go" {
                return .interrupt(with: AnyScene(sub))
            }
            try await ctx.reply("main: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "onenter-main")
        registry.registerScene(sub, commandTrigger: "onenter-sub-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/onenter-main", commandName: "onenter-main"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go"))
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "hi"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /onenter-main",
            "sub onEnter",
            "sub on: hi",
        ])
    }

    @Test(".rollback target's onEnter fires automatically, re-showing its prompt (inside)")
    func onEnterFiresForRollbackTarget() async throws {
        enum State: ConversationState { case first, second }
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<State, EmptySession>(name: "onenter-rollback", initial: .first)
        scene.onEnter(.first) { ctx in
            try await ctx.reply("onEnter: first")
            return .stay
        }
        scene.on(.first) { ctx in
            return .transition(to: .second)
        }
        scene.on(.second) { ctx in
            if ctx.text == "back" {
                return .rollback
            }
            try await ctx.reply("second: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "onenter-rollback")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/onenter-rollback", commandName: "onenter-rollback")) // bootstrap -> onEnter(.first)
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go")) // on(.first) -> transition(to: .second), .second 沒有 onEnter，靜靜等
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "back")) // on(.second) -> .rollback -> 目標 .first 的 onEnter 又自動觸發一次

        #expect(apiClient.sentMessages.map(\.text) == [
            "onEnter: first",
            "onEnter: first",
        ])
    }
}
