import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 先前所有背景任務相關的測試，都是直接呼叫 engine.registerPendingCompletion／
/// deliverBackgroundJobResult，繞過了開發者實際會呼叫的公開 API
/// Context.startBackgroundJob(id:work:onComplete:)——這個函式本體一次都沒被跑過。
/// 這裡透過真正的 dispatch 路徑（scene handler 裡呼叫 ctx.startBackgroundJob）驗證。
@Suite("Context.startBackgroundJob")
struct ContextBackgroundJobTests {
    enum State: ConversationState { case main }

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

    /// 任務「瞬間完成」的排程器：呼叫 work、再呼叫 onComplete，不另外拉一個真的異步
    /// 排程（BackgroundTaskManager 本身已經在另一個 suite 測過了，這裡要測的是
    /// Context 這一層的橋接邏輯，不是排程器本身）。
    struct InstantScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {
            let progress = JobProgress()
            do {
                try await work(progress)
                try? await onComplete(.success)
            } catch {
                try? await onComplete(.failure(error))
            }
        }
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
    }

    func waitUntil(maxAttempts: Int = 200, _ condition: () -> Bool) async {
        for _ in 0..<maxAttempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func waitUntil(maxAttempts: Int = 200, _ condition: () async -> Bool) async {
        for _ in 0..<maxAttempts {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test("startBackgroundJob's onComplete fires through the real Context → engine bridge and can reply")
    func startBackgroundJobNotifiesViaRealBridge() async throws {
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: InstantScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<State, EmptySession>(name: "job", initial: .main)
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t1", work: { progress in
                await progress.update("working")
            }, onComplete: { result, taskID, ctx in
                switch result {
                case .success:
                    try await ctx.reply("job \(taskID) finished")
                case .failure:
                    try await ctx.reply("job \(taskID) failed")
                }
                return nil
            })
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "job")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job", commandName: "job"))

        await waitUntil { !apiClient.sentMessages.isEmpty }

        #expect(apiClient.sentMessages.count == 1)
        #expect(apiClient.sentMessages[0].text == "job t1 finished")
    }

    @Test("a failing work closure reaches onComplete as .failure through the real bridge (outside)")
    func startBackgroundJobFailurePath() async throws {
        struct DummyError: Error {}
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: InstantScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<State, EmptySession>(name: "job", initial: .main)
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t2", work: { _ in
                throw DummyError()
            }, onComplete: { result, taskID, ctx in
                if case .failure = result {
                    try await ctx.reply("job \(taskID) failed as expected")
                } else {
                    try await ctx.reply("unexpected success")
                }
                return nil
            })
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "job")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job", commandName: "job"))

        await waitUntil { !apiClient.sentMessages.isEmpty }

        #expect(apiClient.sentMessages[0].text == "job t2 failed as expected")
    }

    @Test("ctx.backgroundJobStatus(id:) exposes the scheduler's status to the developer (inside)")
    func backgroundJobStatusExposesSchedulerStatus() async throws {
        // BackgroundTaskScheduling.status(chatID:taskID:) 一直都存在，但 Context／
        // GlobalContext 完全沒有方法可以呼叫它——開發者寫不出「/status 查進度」這種指令
        // （對照需求書 US-3 才發現的落差）。這裡驗證新加的 ctx.backgroundJobStatus(id:)
        // 真的把 scheduler 回傳的東西轉交給開發者。
        struct StubScheduler: BackgroundTaskScheduling {
            func start(
                chatID: Int64, taskID: String,
                work: @escaping @Sendable (JobProgress) async throws -> Void,
                onComplete: @escaping @Sendable (JobResult) async throws -> Void
            ) async {}
            func status(chatID: Int64, taskID: String) async -> JobStatus? {
                guard taskID == "known-task" else { return nil }
                return JobStatus(taskID: taskID, lastMessage: "70% 完成", isFinished: false)
            }
        }
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: StubScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<State, EmptySession>(name: "status", initial: .main)
        scene.on(.main) { ctx in
            let known = await ctx.backgroundJobStatus(id: "known-task")
            let unknown = await ctx.backgroundJobStatus(id: "no-such-task")
            try await ctx.reply("known=\(known?.lastMessage ?? "nil") unknown=\(unknown == nil)")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "status")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/status", commandName: "status"))

        #expect(apiClient.sentMessages.last?.text == "known=70% 完成 unknown=true")
    }

    /// 手動控制何時觸發 onComplete 的排程器：不像 InstantScheduler 一啟動就立刻完成，
    /// 讓測試能在「任務還沒完成」跟「任務完成」中間插入別的動作（例如模擬使用者 /cancel），
    /// 這是驗證 Phase 2（transition 套用回對話狀態）需要的時序控制。
    actor ManualScheduler: BackgroundTaskScheduling {
        private var pendingCompletions: [String: @Sendable (JobResult) async throws -> Void] = [:]

        private func key(_ chatID: Int64, _ taskID: String) -> String { "\(chatID):\(taskID)" }

        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {
            pendingCompletions[key(chatID, taskID)] = onComplete
        }
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }

        func hasPending(chatID: Int64, taskID: String) -> Bool {
            pendingCompletions[key(chatID, taskID)] != nil
        }
        func trigger(chatID: Int64, taskID: String, result: JobResult) async {
            guard let completion = pendingCompletions.removeValue(forKey: key(chatID, taskID)) else { return }
            try? await completion(result)
        }
    }

    @Test("onComplete's .transition(to:) is applied: the next dispatch runs the new state's handler (inside)")
    func onCompleteTransitionAdvancesConversationState() async throws {
        enum JobState: ConversationState { case main, done }

        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let scheduler = ManualScheduler()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: scheduler,
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<JobState, EmptySession>(name: "job", initial: .main)
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t3", work: { _ in }, onComplete: { _, _, _ in
                .transition(to: .done)
            })
            return .stay
        }
        scene.on(.done) { ctx in
            try await ctx.reply("reached done state")
            return .end
        }
        registry.registerScene(scene, commandTrigger: "job")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job", commandName: "job"))
        await waitUntil { await scheduler.hasPending(chatID: 1, taskID: "t3") }

        await scheduler.trigger(chatID: 1, taskID: "t3", result: .success)
        // 這個 onComplete 本身不會送任何訊息（只回傳 transition），沒有訊息可以拿來 waitUntil，
        // 給 fire-and-forget 的 applyBackgroundTransition 一點時間真的把 record 存回 StateStore
        try? await Task.sleep(nanoseconds: 20_000_000)

        // 下一輪隨便一句話：如果 transition 真的套用了，這輪應該直接命中 .done 的 handler
        // （因為 .main 只會 .stay，不會自己主動回話說 "reached done state"）
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "anything"))

        #expect(apiClient.sentMessages.contains { $0.text == "reached done state" })
    }

    // applyBackgroundTransition（背景任務完成觸發的轉移）跟 dispatch()（使用者傳訊息
    // 觸發的轉移）原本是兩條分開的路徑，補 onEnter 的時候只接上了 dispatch() 那條，
    // applyBackgroundTransition 沒接——這條測試補上這個情境：背景任務完成後轉移到的
    // state 有註冊 onEnter，應該不用等使用者下一句話就自動顯示。
    @Test("onComplete's .transition(to:) target state's onEnter fires automatically too, not just on the next real Update (inside)")
    func onCompleteTransitionTriggersOnEnter() async throws {
        enum JobState: ConversationState { case main, done }

        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let scheduler = ManualScheduler()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: scheduler,
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<JobState, EmptySession>(name: "job-onenter", initial: .main)
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t5", work: { _ in }, onComplete: { _, _, _ in
                .transition(to: .done)
            })
            return .stay
        }
        scene.onEnter(.done) { ctx in
            try await ctx.reply("onEnter: done automatically")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "job-onenter")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job-onenter", commandName: "job-onenter"))
        await waitUntil { await scheduler.hasPending(chatID: 1, taskID: "t5") }

        await scheduler.trigger(chatID: 1, taskID: "t5", result: .success)
        await waitUntil { apiClient.sentMessages.contains { $0.text == "onEnter: done automatically" } }

        #expect(apiClient.sentMessages.contains { $0.text == "onEnter: done automatically" })
    }

    @Test("onComplete's transition is NOT applied if the user already left the scene, e.g. via /cancel (outside)")
    func onCompleteTransitionSkippedWhenSceneNoLongerActive() async throws {
        enum JobState: ConversationState { case main, done }

        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let scheduler = ManualScheduler()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: scheduler,
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<JobState, EmptySession>(name: "job", initial: .main)
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t4", work: { _ in }, onComplete: { _, _, _ in
                .transition(to: .done)
            })
            return .stay
        }
        scene.on(.done) { ctx in
            try await ctx.reply("reached done state")
            return .end
        }
        registry.registerScene(scene, commandTrigger: "job")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job", commandName: "job"))
        await waitUntil { await scheduler.hasPending(chatID: 1, taskID: "t4") }

        // 模擬使用者在任務跑的期間，用 /cancel 離開了這個 scene（見 GlobalContext.resetConversation）
        await engine.resetConversation(chatID: 1)

        await scheduler.trigger(chatID: 1, taskID: "t4", result: .success)
        // 給 fire-and-forget 的套用邏輯一點時間跑完（就算它什麼都不該做）
        try? await Task.sleep(nanoseconds: 20_000_000)

        // 使用者已經不在 "job" scene 裡了，這輪不該命中 .done 的 handler
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "anything"))

        #expect(!apiClient.sentMessages.contains { $0.text == "reached done state" })
    }

    // 缺口 #5：如果使用者在背景任務執行期間，透過正常 dispatch() 在同一個 scene 裡
    // 又編輯過 session，任務完成時過去會用「任務啟動當下那份舊 session」把使用者的
    // 編輯整個覆蓋掉。下面 3 條測試驗證修好之後：較新的 session 會被保留，不會被
    // 任務那份舊快照蓋掉——分別涵蓋 .moved（onComplete 回傳 .transition(to:)）、
    // 沒有真的競爭的正常情況（迴歸）、.stayed（onComplete 回傳 .stay）三種路徑。
    struct ConflictSession: Codable, Sendable {
        var value: String = "initial"
    }

    @Test("a concurrent session edit made while the job is pending is NOT clobbered by the job's stale snapshot, when onComplete .transition(to:)s (inside: gap #5 fix)")
    func concurrentSessionEditSurvivesTransition() async throws {
        enum JobState: ConversationState { case main, waiting, done }

        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let scheduler = ManualScheduler()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: scheduler,
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<JobState, ConflictSession>(name: "job-conflict-moved", initial: .main, initialSession: ConflictSession())
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t6", work: { _ in }, onComplete: { _, _, ctx in
                ctx.session.value = "from job"
                return .transition(to: .done)
            })
            return .transition(to: .waiting)
        }
        scene.on(.waiting) { ctx in
            if ctx.text == "edit please" {
                ctx.session.value = "edited by user"
            }
            return .stay
        }
        scene.on(.done) { ctx in
            try await ctx.reply("done: \(ctx.session.value)")
            return .end
        }
        registry.registerScene(scene, commandTrigger: "job-conflict-moved")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job-conflict-moved", commandName: "job-conflict-moved"))
        await waitUntil { await scheduler.hasPending(chatID: 1, taskID: "t6") }

        // 任務還沒完成，使用者透過正常 dispatch() 在同一個 scene 裡編輯了 session
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "edit please"))

        await scheduler.trigger(chatID: 1, taskID: "t6", result: .success)
        try? await Task.sleep(nanoseconds: 20_000_000)

        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "anything"))

        // 狀態轉移（.main -> .waiting -> .done）仍然照開發者的決定套用，只有 session
        // 的部分保留使用者較新那份，不是被任務啟動當下那份舊快照蓋掉
        #expect(apiClient.sentMessages.contains { $0.text == "done: edited by user" })
        #expect(!apiClient.sentMessages.contains { $0.text == "done: from job" })
    }

    @Test("without a concurrent edit, onComplete's session change is applied normally (regression, no false-positive conflict)")
    func noConcurrentEditAppliesJobSessionNormally() async throws {
        enum JobState: ConversationState { case main, waiting, done }

        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let scheduler = ManualScheduler()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: scheduler,
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<JobState, ConflictSession>(name: "job-noconflict", initial: .main, initialSession: ConflictSession())
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t7", work: { _ in }, onComplete: { _, _, ctx in
                ctx.session.value = "from job"
                return .transition(to: .done)
            })
            return .transition(to: .waiting)
        }
        scene.on(.waiting) { ctx in
            if ctx.text == "edit please" {
                ctx.session.value = "edited by user"
            }
            return .stay
        }
        scene.on(.done) { ctx in
            try await ctx.reply("done: \(ctx.session.value)")
            return .end
        }
        registry.registerScene(scene, commandTrigger: "job-noconflict")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job-noconflict", commandName: "job-noconflict"))
        await waitUntil { await scheduler.hasPending(chatID: 1, taskID: "t7") }

        // 這次不模擬使用者編輯，session 應該還是任務啟動當下那份，沒有衝突

        await scheduler.trigger(chatID: 1, taskID: "t7", result: .success)
        try? await Task.sleep(nanoseconds: 20_000_000)

        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "anything"))

        #expect(apiClient.sentMessages.contains { $0.text == "done: from job" })
    }

    @Test("a concurrent session edit also survives through the .stay branch (onComplete returns .stay, not .transition) (inside)")
    func concurrentSessionEditSurvivesStay() async throws {
        enum JobState: ConversationState { case main, waiting }

        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let scheduler = ManualScheduler()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: scheduler,
            logger: Logger(label: "test"),
            registry: registry
        )

        let scene = Scene<JobState, ConflictSession>(name: "job-conflict-stay", initial: .main, initialSession: ConflictSession())
        scene.on(.main) { ctx in
            ctx.startBackgroundJob(id: "t8", work: { _ in }, onComplete: { _, _, ctx in
                ctx.session.value = "from job"
                return .stay
            })
            return .transition(to: .waiting)
        }
        scene.on(.waiting) { ctx in
            if ctx.text == "edit please" {
                ctx.session.value = "edited by user"
                return .stay
            }
            try await ctx.reply("waiting: \(ctx.session.value)")
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "job-conflict-stay")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/job-conflict-stay", commandName: "job-conflict-stay"))
        await waitUntil { await scheduler.hasPending(chatID: 1, taskID: "t8") }

        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "edit please"))

        await scheduler.trigger(chatID: 1, taskID: "t8", result: .success)
        try? await Task.sleep(nanoseconds: 20_000_000)

        await engine.dispatch(update: Update(updateID: 3, chatID: 1, text: "anything"))

        #expect(apiClient.sentMessages.contains { $0.text == "waiting: edited by user" })
        #expect(!apiClient.sentMessages.contains { $0.text == "waiting: from job" })
    }
}
