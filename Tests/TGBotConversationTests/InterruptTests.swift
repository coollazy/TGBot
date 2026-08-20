import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// US-1「暫時打斷後恢復」：一個 scene 可以用 .interrupt(with:) 暫停自己、切去跑另一個
/// scene，等那個 scene .end 之後自動恢復回原本暫停的地方繼續——之前這個分支直接
/// fatalError，完全沒實作。這裡驗證的是最小版本：自動恢復，不含「子流程結果自動
/// 傳回上層」那個更複雜的資料交還機制（範圍已經跟使用者確認過）。
///
/// dispatch() 對「剛切換進去的新 scene」跟「頂層指令觸發的 scene」用同一套規則：
/// 進入當下就立刻用同一筆 update 執行新 scene 的 initial state handler，不用使用者
/// 多送一句沒意義的訊息才會看到反應——所以底下的 sub-scene 設計都遵循既有慣例：
/// entry 那個 state 忽略觸發用的文字，問自己的第一個問題，下一個 state 才處理真正的答案。
@Suite("Interrupt / scene stack")
struct InterruptTests {
    enum MainState: ConversationState { case main }
    enum SubState: ConversationState { case sub, subAnswer }

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

    /// .main 收到 "sub" 就中斷去跑子流程，其他任何輸入都只是回話、留在原地（.stay），
    /// 這樣才能確定性地控制「什麼時候觸發中斷」。
    func makeMainScene(subScene: Scene<SubState, EmptySession>) -> Scene<MainState, EmptySession> {
        let scene = Scene<MainState, EmptySession>(name: "main", initial: .main)
        scene.on(.main) { ctx in
            if ctx.text == "sub" {
                return .interrupt(with: AnyScene(subScene))
            }
            try await ctx.reply("main: \(ctx.text ?? "")")
            return .stay
        }
        return scene
    }

    /// entry（.sub）忽略觸發文字、問自己的問題；.subAnswer 處理真正的答案——如果答案是
    /// "go deeper" 且有提供更深一層的 scene，就再中斷一次，否則回話＋結束。
    func makeSubScene(interruptingWith innermost: AnyScene? = nil) -> Scene<SubState, EmptySession> {
        let scene = Scene<SubState, EmptySession>(name: "sub", initial: .sub)
        scene.on(.sub) { ctx in
            try await ctx.reply("sub: what's your favorite color?")
            return .transition(to: .subAnswer)
        }
        scene.on(.subAnswer) { ctx in
            if ctx.text == "go deeper", let innermost {
                return .interrupt(with: innermost)
            }
            try await ctx.reply("sub got: \(ctx.text ?? "")")
            return .end
        }
        return scene
    }

    @Test(".interrupt switches to the sub-flow immediately, showing its first prompt in the same turn (inside)")
    func interruptSwitchesActiveScene() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()
        let main = makeMainScene(subScene: sub)
        registry.registerScene(main, commandTrigger: "main")
        registry.registerScene(sub, commandTrigger: "sub-entry") // 中斷用得到，需要能被 registry 查到

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main", commandName: "main"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub"))
        // 這一輪應該命中子流程 .subAnswer 的 handler，不是 main 的
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "blue"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main",
            "sub: what's your favorite color?",
            "sub got: blue",
        ])
    }

    // register(_:trigger:) 的 trigger 原本強制必填，逼著子流程 scene 就算不想開放使用者
    // 直接打指令進入，也得掰一個用不到的指令出去，不然撐不過第一輪 dispatch 就會找不到
    // 這個 scene（因為 registry 只有透過 registerScene(_:commandTrigger:) 才會寫進
    // 「用名字查回 scene」那份索引，之前這份索引綁死在有沒有給 commandTrigger 上面）。
    // 這裡驗證改成 optional 之後，完全不給 trigger 的子流程一樣能正常撐過多輪對話。
    @Test("a sub-flow registered with no trigger (interrupt-only, never a standalone command) still survives multiple dispatch turns (boundary: nil trigger)")
    func subFlowWithNoTriggerSurvivesMultipleTurns() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()
        let main = makeMainScene(subScene: sub)
        registry.registerScene(main, commandTrigger: "main")
        registry.registerScene(sub, commandTrigger: nil) // 不開放指令，只能被中斷帶進來

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main", commandName: "main"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub")) // 中斷進場，第一輪靠直接傳的物件參照，不會測到這個修復
        // 這一輪才是關鍵：sub 上一輪存進 record 的只有名字字串，這裡要真的能靠
        // registry.scene(named:) 查回來，不能因為沒給 trigger 就找不到
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "blue"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main",
            "sub: what's your favorite color?",
            "sub got: blue",
        ])
    }

    @Test("when the sub-flow ends, the interrupted main flow automatically resumes where it paused (inside)")
    func subFlowEndResumesMainFlow() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()
        let main = makeMainScene(subScene: sub)
        registry.registerScene(main, commandTrigger: "main")
        registry.registerScene(sub, commandTrigger: "sub-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main", commandName: "main"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub")) // 中斷，立刻看到子流程第一句話
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "blue")) // 子流程處理完，.end

        // 子流程結束了，這一輪應該自動回到 main scene 的 .main（中斷當下那個 state），
        // 不需要使用者再打一次 /main
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "back to main"))

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main",
            "sub: what's your favorite color?",
            "sub got: blue",
            "main: back to main",
        ])
    }

    @Test("a normal .end with no interrupt ever happening still fully resets, unaffected by the scene stack (outside: regression)")
    func plainEndWithoutInterruptStillResetsNormally() async throws {
        enum SoloState: ConversationState { case only }
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<SoloState, EmptySession>(name: "solo", initial: .only)
        scene.on(.only) { ctx in
            try await ctx.reply("solo: \(ctx.text ?? "")")
            return .end
        }
        registry.registerScene(scene, commandTrigger: "solo")

        // 這個流程從頭到尾沒有中斷過，sceneStack 全程是空的
        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/solo", commandName: "solo"))
        // 已經 .end 了，這輪不該命中任何東西（沒有 active scene，文字也不是任何指令）
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "anything"))

        #expect(apiClient.sentMessages.map(\.text) == ["solo: /solo"])
    }

    @Test("nested interrupts (a sub-flow interrupted by another sub-flow) unwind in the correct order (boundary: depth > 1)")
    func nestedInterruptsUnwindInOrder() async throws {
        enum InnerState: ConversationState { case inner, innerAnswer }

        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let innermost = Scene<InnerState, EmptySession>(name: "innermost", initial: .inner)
        innermost.on(.inner) { ctx in
            try await ctx.reply("innermost: what's your favorite animal?")
            return .transition(to: .innerAnswer)
        }
        innermost.on(.innerAnswer) { ctx in
            try await ctx.reply("innermost got: \(ctx.text ?? "")")
            return .end
        }

        let sub = makeSubScene(interruptingWith: AnyScene(innermost))
        let main = makeMainScene(subScene: sub)
        registry.registerScene(main, commandTrigger: "main")
        registry.registerScene(sub, commandTrigger: "sub-entry")
        registry.registerScene(innermost, commandTrigger: "innermost-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main", commandName: "main"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub")) // main -> sub（立刻問顏色）
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "go deeper")) // sub -> innermost（立刻問動物）
        await engine.dispatch(update: Update(updateID: 4, chatID: 1, text: "cat")) // innermost .end -> 彈回 sub
        await engine.dispatch(update: Update(updateID: 5, chatID: 1, text: "red")) // sub .end -> 彈回 main
        await engine.dispatch(update: Update(updateID: 6, chatID: 1, text: "done")) // main 的 .main

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main",
            "sub: what's your favorite color?",
            "innermost: what's your favorite animal?",
            "innermost got: cat",
            "sub got: red",
            "main: done",
        ])
    }

    // 實機測試發現的真實落差：子流程結束、自動恢復主流程之後，使用者完全不知道發生了
    // 什麼事——下一句話只會撞上原本 state 的 handler（可能是驗證失敗訊息之類），
    // 聽起來像使用者自己答錯了，但其實只是被晾在那裡。onResume(_:handler:) 就是為了
    // 讓開發者能在「真的恢復的那一刻」主動交代現在在等什麼，不是框架自己亂猜一句通用訊息。
    @Test("a registered onResume handler fires exactly when the interrupted scene resumes (inside)")
    func onResumeFiresWhenSceneResumes() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()
        let main = makeMainScene(subScene: sub)
        main.onResume(.main) { ctx in
            try await ctx.reply("welcome back!")
        }
        registry.registerScene(main, commandTrigger: "main")
        registry.registerScene(sub, commandTrigger: "sub-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main", commandName: "main"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub"))
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "blue")) // sub .end -> 彈回 main，觸發 onResume

        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main",
            "sub: what's your favorite color?",
            "sub got: blue",
            "welcome back!",
        ])
    }

    @Test("without a registered onResume handler, resuming stays silent as before — opt-in, not forced (outside: regression)")
    func noOnResumeHandlerStaysSilent() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)
        let sub = makeSubScene()
        let main = makeMainScene(subScene: sub) // 沒有呼叫 main.onResume(...)
        registry.registerScene(main, commandTrigger: "main")
        registry.registerScene(sub, commandTrigger: "sub-entry")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/main", commandName: "main"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "sub"))
        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "blue"))

        // 沒有多出任何一句「welcome back」之類的訊息——維持加這個功能之前的行為
        #expect(apiClient.sentMessages.map(\.text) == [
            "main: /main",
            "sub: what's your favorite color?",
            "sub got: blue",
        ])
    }
}
