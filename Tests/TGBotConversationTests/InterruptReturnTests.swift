import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 子流程結果自動傳回被中斷的流程：`.interrupt(with:onReturn:)` + `.end(with:)`。
/// 對照既有 `InterruptTests.swift`（Phase 4 的最小版本，只做「自動恢復」）——這裡驗證的
/// 是使用者明確表示才是真實需求的部分：子流程收集到的資料要能型別安全地帶回父流程，
/// 讓父流程的 `onReturn` 決定接下來怎麼走，而不是只能靠外部共享狀態繞過去。
@Suite("Interrupt result handback")
struct InterruptReturnTests {
    enum MainState: ConversationState { case main, afterReturn }
    enum SubState: ConversationState { case sub, subAnswer }
    enum GrandchildState: ConversationState { case grandchild, grandchildAnswer }

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

    /// entry（.sub）忽略觸發文字、問問題；.subAnswer 處理真正的答案，帶著結果
    /// .end(with:) 出去——跟 InterruptTests.makeSubScene 同一個 entry/answer 兩段式
    /// 設計，避免用可變的閉包捕獲變數（Swift 6 嚴格併發不允許）。
    func makeSubScene() -> Scene<SubState, EmptySession> {
        let scene = Scene<SubState, EmptySession>(name: "sub-return", initial: .sub)
        scene.on(.sub) { ctx in
            try await ctx.reply("sub: what's the answer?")
            return .transition(to: .subAnswer)
        }
        scene.on(.subAnswer) { ctx in
            return try .end(with: ctx.text ?? "")
        }
        return scene
    }

    @Test(".end(with:) hands the typed result back to onReturn (inside)")
    func onReturnReceivesTypedResult() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()

        let main = Scene<MainState, EmptySession>(name: "main-return", initial: .main)
        main.on(.main) { ctx in
            if ctx.text == "sub" {
                return .interrupt(with: AnyScene(sub)) { (answer: String, ctx: Context<MainState, EmptySession>) in
                    try await ctx.reply("main got back: \(answer)")
                    return .stay
                }
            }
            try await ctx.reply("main: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "main-return")
        registry.registerScene(sub, commandTrigger: "sub-return-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main-return", commandName: "main-return"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub")) // interrupt, sub asks
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "42")) // sub .end(with: "42") -> onReturn

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main-return",
            "sub: what's the answer?",
            "main got back: 42",
        ])
    }

    @Test("onReturn returning .transition(to:) actually advances the parent scene (inside)")
    func onReturnTransitionAdvancesParent() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()

        let main = Scene<MainState, EmptySession>(name: "main-transition", initial: .main)
        main.on(.main) { ctx in
            if ctx.text == "go" {
                return .interrupt(with: AnyScene(sub)) { (answer: String, ctx: Context<MainState, EmptySession>) in
                    return .transition(to: .afterReturn)
                }
            }
            try await ctx.reply("main: \(ctx.text ?? "")")
            return .stay
        }
        main.on(.afterReturn) { ctx in
            try await ctx.reply("afterReturn: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "main-transition")
        registry.registerScene(sub, commandTrigger: "sub-transition-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main-transition", commandName: "main-transition"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go")) // interrupt immediately, sub asks
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "answer")) // sub ends, onReturn -> .transition(to: .afterReturn)（這輪不會立刻執行 afterReturn 的 handler，跟一般 .transition 語意一致）
        // 這一輪才會命中 .afterReturn 的 handler，不是 .main 的（證明真的往下走了，不是停在原地）
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "next"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main-transition",
            "sub: what's the answer?",
            "afterReturn: next",
        ])
    }

    @Test("onReturn returning .end(with:) cascades the result further up a nested interrupt stack (boundary: depth > 1)")
    func onReturnEndCascadesToGrandparent() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        // grandchild：entry 問問題，answer 帶結果 .end(with:) 出去
        let grandchild = Scene<GrandchildState, EmptySession>(name: "grandchild", initial: .grandchild)
        grandchild.on(.grandchild) { ctx in
            try await ctx.reply("grandchild: number?")
            return .transition(to: .grandchildAnswer)
        }
        grandchild.on(.grandchildAnswer) { ctx in
            return try .end(with: Int(ctx.text ?? "") ?? 0)
        }

        // sub（中間層）：進場（不管是被什麼觸發）立刻中斷進 grandchild，grandchild 的結果
        // 透過 sub 的 onReturn 再包一層、用 .end(with:) 繼續往上（main）傳
        let sub = Scene<SubState, EmptySession>(name: "sub-cascade", initial: .sub)
        sub.on(.sub) { ctx in
            return .interrupt(with: AnyScene(grandchild)) { (number: Int, ctx: Context<SubState, EmptySession>) in
                return try .end(with: number * 10)
            }
        }

        let main = Scene<MainState, EmptySession>(name: "main-cascade", initial: .main)
        main.on(.main) { ctx in
            if ctx.text == "go" {
                return .interrupt(with: AnyScene(sub)) { (finalValue: Int, ctx: Context<MainState, EmptySession>) in
                    try await ctx.reply("main received cascaded: \(finalValue)")
                    return .stay
                }
            }
            try await ctx.reply("main: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "main-cascade")
        registry.registerScene(sub, commandTrigger: "sub-cascade-entry")
        registry.registerScene(grandchild, commandTrigger: "grandchild-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main-cascade", commandName: "main-cascade"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go")) // main -> sub -> grandchild（同一輪立刻問數字）
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "4")) // grandchild .end(with: 4) -> sub.onReturn -> .end(with: 40) -> main.onReturn

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main-cascade",
            "grandchild: number?",
            "main received cascaded: 40",
        ])
    }

    @Test("a sub-flow ending with plain .end (no result) does not invoke onReturn, falls back to onResume (outside: regression)")
    func plainEndDoesNotInvokeOnReturn() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, EmptySession>(name: "sub-plain-end", initial: .sub)
        sub.on(.sub) { ctx in
            try await ctx.reply("sub: bye")
            return .end // 沒有帶結果
        }

        let main = Scene<MainState, EmptySession>(name: "main-plain-end", initial: .main)
        main.on(.main) { ctx in
            return .interrupt(with: AnyScene(sub)) { (answer: String, ctx: Context<MainState, EmptySession>) in
                try await ctx.reply("onReturn should NOT fire: \(answer)")
                return .stay
            }
        }
        main.onResume(.main) { ctx in
            try await ctx.reply("onResume fired instead")
        }
        registry.registerScene(main, commandTrigger: "main-plain-end")
        registry.registerScene(sub, commandTrigger: "sub-plain-end-entry")

        // main 進場就立刻中斷（不需要額外的觸發關鍵字）：sub 進場立刻回話並 .end（沒帶結果），
        // 整個「中斷 -> 子流程立刻結束 -> 彈回 -> 因為沒有結果所以走 onResume」都在同一輪完成。
        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main-plain-end", commandName: "main-plain-end"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "sub: bye",
            "onResume fired instead",
        ])
    }

    @Test("plain .interrupt(with:) without onReturn keeps working exactly as before (outside: regression)")
    func plainInterruptWithoutOnReturnUnaffected() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let sub = Scene<SubState, EmptySession>(name: "sub-no-return", initial: .sub)
        sub.on(.sub) { ctx in
            try await ctx.reply("sub: done, no result")
            return .end
        }

        let main = Scene<MainState, EmptySession>(name: "main-no-return", initial: .main)
        main.on(.main) { ctx in
            if ctx.text == "go" {
                return .interrupt(with: AnyScene(sub)) // 舊版重載，沒有 onReturn
            }
            try await ctx.reply("main: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "main-no-return")
        registry.registerScene(sub, commandTrigger: "sub-no-return-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main-no-return", commandName: "main-no-return"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go"))
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "back"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main-no-return",
            "sub: done, no result",
            "main: back",
        ])
    }

    @Test("onReturn returning .interrupt degrades safely to .stay instead of crashing (boundary: unsupported chain)")
    func onReturnReturningInterruptDegradesToStay() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()
        let unreachable = Scene<GrandchildState, EmptySession>(name: "unreachable", initial: .grandchild)
        unreachable.on(.grandchild) { ctx in
            try await ctx.reply("should never run")
            return .end
        }

        let main = Scene<MainState, EmptySession>(name: "main-bad-return", initial: .main)
        main.on(.main) { ctx in
            if ctx.text == "go" {
                return .interrupt(with: AnyScene(sub)) { (answer: String, ctx: Context<MainState, EmptySession>) in
                    .interrupt(with: AnyScene(unreachable)) // 不支援，應該安全退化成 .stay
                }
            }
            try await ctx.reply("main: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(main, commandTrigger: "main-bad-return")
        registry.registerScene(sub, commandTrigger: "sub-bad-return-entry")
        registry.registerScene(unreachable, commandTrigger: "unreachable-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main-bad-return", commandName: "main-bad-return"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "go")) // interrupt, sub asks
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "answer")) // sub ends -> onReturn -> 退化成 .stay，不 crash
        // 下一句話應該還是 main 的 .main handler 在處理（因為退化成 .stay，還留在 main，
        // 不是卡在某個奇怪的中間狀態），"unreachable" scene 應該從未被呼叫過
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "still here"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main-bad-return",
            "sub: what's the answer?",
            "main: still here",
        ])
    }
}
