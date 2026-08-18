import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 先前所有背景任務相關的測試，都是直接呼叫 engine.registerPendingCompletion／
/// deliverBackgroundJobResult，繞過了開發者實際會呼叫的公開 API
/// Context.startBackgroundJob(id:work:onComplete:)——這個函式本體一次都沒被跑過。
/// 這裡透過真正的 dispatch 路徑（scene handler 裡呼叫 ctx.startBackgroundJob）驗證。
///
/// 已知限制（見 Context.swift 內的 TODO）：onComplete 回傳的 Transition 目前還沒有被
/// 套用回對話狀態，只有「通知」這條路徑（ctx.reply 等）是真的接起來的——這裡的測試
/// 只驗證目前真正實作的部分，不假裝 transition 套用已經完成。
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
}
