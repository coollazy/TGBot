import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 端對端驗證「垂直切片」：從 dispatch 一個 Update 進去，經過真正的
/// scene 路由（EngineRegistry）→ 型別擦除（AnyScene）→ handler 執行（Context）→
/// 呼叫 Telegram API（sendMessage），到 ConversationEngine 把新的 state/session
/// 存回 StateStore，全程不碰真實網路，用假的 TelegramAPIClient 攔截送出的訊息。
@Suite("Echo bot end-to-end")
struct EchoBotEndToEndTests {
    enum EchoState: ConversationState { case listening }

    final class RecordingAPIClient: TelegramAPIClient, @unchecked Sendable {
        private(set) var sentMessages: [(chatID: Int64, text: String, buttons: [[TGInlineKeyboardButton]]?)] = []

        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
            sentMessages.append((chatID, text, inlineKeyboard))
        }
        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
        func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {}
        func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws {}
    }

    struct NoOpScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
    }

    @Test("registering an echo scene and dispatching two updates round-trips through the real pipeline")
    func echoRoundTrip() async throws {
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )

        let echo = Scene<EchoState, EmptySession>(name: "echo", initial: .listening)
        echo.on(.listening) { ctx in
            try await ctx.reply("echo: \(ctx.text ?? "")")
            return .stay
        }
        registry.registerScene(echo, commandTrigger: "echo")

        // 第一則：/echo 觸發 bootstrapping，進入 echo scene
        await engine.dispatch(update: Update(updateID: 1, chatID: 42, text: "/echo", commandName: "echo"))
        // 第二則：已經在 echo scene 裡了，純文字應該直接被同一個 handler 接住
        await engine.dispatch(update: Update(updateID: 2, chatID: 42, text: "hello"))

        #expect(apiClient.sentMessages.count == 2)
        #expect(apiClient.sentMessages[0].chatID == 42)
        #expect(apiClient.sentMessages[0].text == "echo: /echo")
        #expect(apiClient.sentMessages[1].text == "echo: hello")
    }

    @Test("resetConversation clears active scene but a background job's pending completion still fires")
    func resetDoesNotCancelPendingCompletion() async throws {
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )

        await engine.registerPendingCompletion(chatID: 7, taskID: "job-1") { _ in
            try await apiClient.sendMessage(chatID: 7, text: "job done")
        }
        await engine.resetConversation(chatID: 7)
        await engine.deliverBackgroundJobResult(chatID: 7, taskID: "job-1", result: .success)

        #expect(apiClient.sentMessages.count == 1)
        #expect(apiClient.sentMessages[0].text == "job done")
    }
}
