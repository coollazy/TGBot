import Testing
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 前一輪的 EchoBotEndToEndTests 只用到 `.stay`，`.transition(to:)`／`.end` 這兩個核心
/// case 完全沒被驗證過——這份補上。也一併驗證 replyWithMenu 真的把按鈕帶出去
/// （上次在 Example 裡發現「按鈕被丟掉只送純文字」的那個 bug，這裡留一個回歸測試守著）。
@Suite("Scene transition handling")
struct SceneTransitionTests {
    enum Step: ConversationState { case first, second, third }
    struct Data: Codable { var visited: [String] = [] }

    final class RecordingAPIClient: TelegramAPIClient, @unchecked Sendable {
        private(set) var sentMessages: [(chatID: Int64, text: String, buttons: [[TGInlineKeyboardButton]]?)] = []

        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
            sentMessages.append((chatID, text, inlineKeyboard))
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

    @Test(".transition(to:) actually moves to the new state for the next dispatch")
    func transitionMovesToNextState() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<Step, Data>(name: "steps", initial: .first, initialSession: Data())
        scene.on(.first) { ctx in
            ctx.session.visited.append("first")
            try await ctx.reply("moving to second")
            return .transition(to: .second)
        }
        scene.on(.second) { ctx in
            ctx.session.visited.append("second")
            try await ctx.reply("visited: \(ctx.session.visited.joined(separator: ","))")
            return .transition(to: .third)
        }
        registry.registerScene(scene, commandTrigger: "steps")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/steps", commandName: "steps"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "anything"))

        #expect(apiClient.sentMessages.count == 2)
        #expect(apiClient.sentMessages[0].text == "moving to second")
        // 第二次 dispatch 真的是 .second 的 handler 在處理，而且 session（visited 陣列）
        // 有跨兩次 dispatch 正確累積，不是每次都拿到一個全新的空 session
        #expect(apiClient.sentMessages[1].text == "visited: first,second")
    }

    @Test(".end clears the active scene so the chat goes back to idle")
    func endClearsActiveScene() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<Step, Data>(name: "steps", initial: .first, initialSession: Data())
        scene.on(.first) { ctx in
            try await ctx.reply("done")
            return .end
        }
        registry.registerScene(scene, commandTrigger: "steps")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/steps", commandName: "steps"))
        // scene 已經 .end 了，這裡再傳一句無關的話，不應該又被 .first 的 handler 接住
        // （如果 .end 沒有真的清空 activeScene，這句會被誤判成又進了一次 .first，重複回 "done"）
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, text: "hello again"))

        #expect(apiClient.sentMessages.count == 1)
        #expect(apiClient.sentMessages[0].text == "done")
    }

    @Test("replyWithMenu actually carries the inline keyboard through to the API client, not just plain text")
    func replyWithMenuIncludesButtons() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<Step, Data>(name: "menu", initial: .first, initialSession: Data())
        scene.on(.first) { ctx in
            try await ctx.replyWithMenu("pick one", buttons: [[
                InlineButton(text: "A", callbackData: "a"),
                InlineButton(text: "B", callbackData: "b"),
            ]])
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "menu")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/menu", commandName: "menu"))

        let sent = apiClient.sentMessages[0]
        #expect(sent.text == "pick one")
        let buttons = try #require(sent.buttons)
        #expect(buttons.count == 1)
        #expect(buttons[0].map(\.text) == ["A", "B"])
        #expect(buttons[0].map(\.callbackData) == ["a", "b"])
    }

    @Test("callback_query data reaches the handler as ctx.callbackData, driving the same dispatch path as text")
    func callbackDataDrivesTransition() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient)

        let scene = Scene<Step, Data>(name: "pick", initial: .first, initialSession: Data())
        scene.on(.first) { ctx in
            try await ctx.replyWithMenu("pick", buttons: [[InlineButton(text: "Go", callbackData: "go")]])
            return .transition(to: .second)
        }
        scene.on(.second) { ctx in
            try await ctx.reply("got: \(ctx.callbackData ?? "nothing")")
            return .end
        }
        registry.registerScene(scene, commandTrigger: "pick")

        await engine.dispatch(update: Update(updateID: 1, chatID: 1, text: "/pick", commandName: "pick"))
        await engine.dispatch(update: Update(updateID: 2, chatID: 1, callbackData: "go"))

        #expect(apiClient.sentMessages[1].text == "got: go")
    }
}
