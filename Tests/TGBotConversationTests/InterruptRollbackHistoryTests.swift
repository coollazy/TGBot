import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// `.interrupt` 中斷時，被中斷那個流程的 rollback 歷史（`Transition.rollback` 要退回去的
/// 依據）過去一直會被清空——`SuspendedScene` 只存了 `savedState`／`savedSession`，恢復時
/// `stateHistory` 永遠重設成 `[]`。這裡驗證修好之後：中斷前走過的步驟，恢復後 `.rollback`
/// 真的退得回去，不管是走 `.interrupt(with:)`（純中斷）還是 `.interrupt(with:onReturn:)`
/// （onReturn 自己又觸發 `.transition`／`.rollback`）。
@Suite("Interrupt preserves rollback history")
struct InterruptRollbackHistoryTests {
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

    @Test("plain .interrupt(with:): after the sub-flow ends and the parent resumes, .rollback returns to the step before the interrupt (inside)")
    func plainInterruptPreservesHistoryAcrossResume() async throws {
        enum MainState: ConversationState { case step1, step2 }
        enum SubState: ConversationState { case sub }

        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, EmptySession>(name: "hist-sub", initial: .sub)
        sub.on(.sub) { ctx in
            try await ctx.reply("sub: hello")
            return .end // 沒帶結果，純中斷，走 onResume/靜默那條路徑
        }

        let main = Scene<MainState, EmptySession>(name: "hist-main", initial: .step1)
        main.on(.step1) { ctx in
            try await ctx.reply("step1")
            return .transition(to: .step2) // history 現在有一筆：[step1]
        }
        main.on(.step2) { ctx in
            if ctx.text == "sub" {
                return .interrupt(with: AnyScene(sub))
            }
            if ctx.text == "back" {
                return .rollback
            }
            try await ctx.reply("step2: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "hist-main")
        registry.registerScene(sub, commandTrigger: "hist-sub-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/hist-main", commandName: "hist-main")) // step1 -> step2
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub")) // 中斷去 sub，sub 立刻回話並結束，恢復回 step2
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "back")) // .rollback：修好之前這裡會因為歷史是空的而退化成 .stay（停在 step2）
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "anything")) // 如果真的退回 step1，這裡應該命中 step1 的 handler

        #expect(apiClient.sentMessages.map(\.text) == [
            "step1",
            "sub: hello",
            "step1",
        ])
    }

    @Test(".interrupt(with:onReturn:): onReturn's own .transition(to:) pushes onto the restored parent history, not a fresh empty one (inside)")
    func onReturnTransitionPushesOntoRestoredHistory() async throws {
        enum MainState: ConversationState { case step1, step2, afterReturn }
        enum SubState: ConversationState { case sub, subAnswer }

        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, EmptySession>(name: "hist-sub2", initial: .sub)
        sub.on(.sub) { ctx in
            try await ctx.reply("sub2: answer?")
            return .transition(to: .subAnswer)
        }
        sub.on(.subAnswer) { ctx in
            return try .end(with: ctx.text ?? "")
        }

        let main = Scene<MainState, EmptySession>(name: "hist-main2", initial: .step1)
        main.on(.step1) { ctx in
            try await ctx.reply("step1")
            return .transition(to: .step2) // history: [step1]
        }
        main.on(.step2) { ctx in
            if ctx.text == "sub" {
                return .interrupt(with: AnyScene(sub)) { (answer: String, ctx: Context<MainState, EmptySession>) in
                    return .transition(to: .afterReturn) // 期待 push 到 [step1, step2]，不是 [step2]
                }
            }
            try await ctx.reply("step2: \(ctx.text ?? "")")
            return .stay
        }
        main.on(.afterReturn) { ctx in
            if ctx.text == "back" {
                return .rollback
            }
            try await ctx.reply("afterReturn: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "hist-main2")
        registry.registerScene(sub, commandTrigger: "hist-sub2-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/hist-main2", commandName: "hist-main2")) // step1 -> step2
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub")) // 中斷，sub 立刻問問題
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "42")) // sub .end(with:) -> onReturn -> .transition(to: .afterReturn)
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "back")) // .rollback：應該退回 step2，不是退化成停在 afterReturn
        await engine.dispatch(update: Update(updateID: 5, chatID: 1, text: "anything")) // 如果真的在 step2，這裡命中 step2 的 handler

        #expect(apiClient.sentMessages.map(\.text) == [
            "step1",
            "sub2: answer?",
            "step2: anything",
        ])
    }

    @Test(".interrupt(with:onReturn:): onReturn directly returning .rollback actually rolls back the parent (not a forced degrade to .stay) (inside)")
    func onReturnRollbackActuallyRollsBack() async throws {
        enum MainState: ConversationState { case step1, step2 }
        enum SubState: ConversationState { case sub, subAnswer }

        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, EmptySession>(name: "hist-sub3", initial: .sub)
        sub.on(.sub) { ctx in
            try await ctx.reply("sub3: answer?")
            return .transition(to: .subAnswer)
        }
        sub.on(.subAnswer) { ctx in
            return try .end(with: ctx.text ?? "")
        }

        let main = Scene<MainState, EmptySession>(name: "hist-main3", initial: .step1)
        main.on(.step1) { ctx in
            try await ctx.reply("step1")
            return .transition(to: .step2) // history: [step1]
        }
        main.on(.step2) { ctx in
            if ctx.text == "sub" {
                return .interrupt(with: AnyScene(sub)) { (answer: String, ctx: Context<MainState, EmptySession>) in
                    return .rollback // 直接在 onReturn 裡退回去，過去這裡一律安全退化成 .stay
                }
            }
            try await ctx.reply("step2: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "hist-main3")
        registry.registerScene(sub, commandTrigger: "hist-sub3-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/hist-main3", commandName: "hist-main3")) // step1 -> step2
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub")) // 中斷，sub 立刻問問題
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "x")) // sub .end(with:) -> onReturn -> .rollback -> 應該真的退回 step1
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "y")) // 如果真的在 step1，這裡命中 step1 的 handler（會再回 "step1"）

        #expect(apiClient.sentMessages.map(\.text) == [
            "step1",
            "sub3: answer?",
            "step1",
        ])
    }
}
