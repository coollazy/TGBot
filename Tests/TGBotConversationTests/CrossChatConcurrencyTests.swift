import Testing
import Foundation
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 驗證 README「已知限制」修復後的效果：即使某個 chat 的 handler 寫了完全不 await、
/// 長時間佔用 CPU 的同步運算，也不會拖累另一個 chat 的 dispatch。
///
/// 實作記錄：一開始評估過把 `ConversationEngine` 內部拆成 per-chat 動態建立的 actor
/// （文件／程式碼註解裡標注的下一階段目標），實測發現這個拆分對這支測試的結果沒有
/// 影響——不管 `ConversationEngine` 是單一 actor 還是拆成多個，這個測試都會過。
/// 原因：`Scene.on(...)` 註冊的 handler 是純 `@Sendable async` closure，沒有綁定
/// 任何 actor isolation，呼叫它時 Swift 本來就會跳到 global executor 執行，不會被
/// `ConversationEngine` 的 actor isolation 卡住，所以 per-chat actor 拆分對「使用者
/// handler 裡的同步運算會不會拖累別的 chat」這件事沒有實際效益，最後決定不拆，維持
/// 單一 actor（見 `ConversationEngine.swift` 開頭註解）。這支測試真正驗證、也真正
/// 依賴的是 `PollingUpdateSource` 的修復（見 PollingUpdateSourceTests）：呼叫端要
/// 真的並發呼叫 `dispatch(update:)`，不同 chat 的 handler 才有機會同時被排上不同
/// 執行緒跑。
@Suite("Cross-chat parallelism")
struct CrossChatConcurrencyTests {
    enum SoloState: ConversationState { case initial }

    /// 記錄送出訊息的順序——這支測試真正要看的就是「done-fast 先送出，還是
    /// done-busy 先送出」。用 actor（而非 NSLock）管理內部狀態：Swift 6 底下
    /// NSLock.lock()/unlock() 不能直接在 async 函式裡呼叫（避免鎖跨越 suspension
    /// point），actor 是更正規的做法，跟 PollingUpdateSourceTests 的 ScriptedAPIClient
    /// 同一套理由。
    actor RecordingAPIClient: TelegramAPIClient {
        private(set) var sentTexts: [String] = []

        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
            sentTexts.append(text)
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

    @Test("a CPU-bound handler with no await in one chat does not block another chat's dispatch")
    func busyChatDoesNotBlockOtherChat() async throws {
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )

        let busy = Scene<SoloState, EmptySession>(name: "busy", initial: .initial)
        busy.on(.initial) { ctx in
            // 故意完全不 await：純同步忙碌迴圈，模擬「handler 裡有長時間同步運算」的情境。
            let deadline = Date().addingTimeInterval(0.2)
            while Date() < deadline {}
            try await ctx.reply("done-busy")
            return .stay
        }
        registry.registerScene(busy, commandTrigger: "busy")

        let fast = Scene<SoloState, EmptySession>(name: "fast", initial: .initial)
        fast.on(.initial) { ctx in
            try await ctx.reply("done-fast")
            return .stay
        }
        registry.registerScene(fast, commandTrigger: "fast")

        async let busyTask: Void = engine.dispatch(
            update: Update(updateID: 1, chatID: 1, text: "/busy", commandName: "busy")
        )
        // 讓 busy 的 dispatch 先確實進入忙碌迴圈，再送 fast 的，避免測試單純比誰先被排程到
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let fastTask: Void = engine.dispatch(
            update: Update(updateID: 2, chatID: 2, text: "/fast", commandName: "fast")
        )

        _ = await (busyTask, fastTask)

        // 核心斷言：done-fast 應該遠早於 done-busy 送出——如果呼叫端又退回「處理完一筆
        // update 才處理下一筆」（PollingUpdateSource 修復前的行為），fast 的 dispatch
        // 根本不會在 busy 還沒處理完之前被送出去，這支測試就會逾時／斷言失敗。
        let sentTexts = await apiClient.sentTexts
        #expect(sentTexts == ["done-fast", "done-busy"])
    }
}
