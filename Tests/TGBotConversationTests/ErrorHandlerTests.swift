import Testing
import Foundation
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 對照需求書才發現的落差：TGBot.onError(_:) 註冊了 handler，但從頭到尾沒有任何地方
/// 真的呼叫過它——scene handler 拋錯只會被 ConversationEngine 記 log，開發者自己的
/// hook 完全收不到通知。這裡驗證接上之後：有註冊 hook 時真的會被呼叫、拿到同一個
/// error；沒註冊時維持原本「只記 log、不會整個 dispatch 掛掉」的行為不變。
@Suite("onError hook")
struct ErrorHandlerTests {
    enum State: ConversationState { case only }
    struct BoomError: Error, CustomStringConvertible {
        var description: String { "boom" }
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

    struct NoOpScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    @Test("a scene handler throwing invokes the registered onError hook with the same error (inside)")
    func onErrorHookIsInvokedWhenHandlerThrows() async throws {
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )

        let capturedChatID = Box<Int64?>(nil)
        let capturedErrorDescription = Box<String?>(nil)
        registry.setErrorHandler { ctx, error in
            capturedChatID.value = ctx.chatID
            capturedErrorDescription.value = "\(error)"
        }

        let scene = Scene<State, EmptySession>(name: "boom", initial: .only)
        scene.on(.only) { _ in throw BoomError() }
        registry.registerScene(scene, commandTrigger: "boom")

        await engine.dispatch(update: Update(updateID: 1, chatID: 42, text: "/boom", commandName: "boom"))

        #expect(capturedChatID.value == 42)
        #expect(capturedErrorDescription.value == "boom")
    }

    @Test("without a registered onError hook, a thrown error is only logged and dispatch doesn't crash (outside)")
    func noHookRegisteredDoesNotCrash() async throws {
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )
        // 故意不呼叫 registry.setErrorHandler(...)

        let scene = Scene<State, EmptySession>(name: "boom", initial: .only)
        scene.on(.only) { _ in throw BoomError() }
        registry.registerScene(scene, commandTrigger: "boom")

        await engine.dispatch(update: Update(updateID: 1, chatID: 42, text: "/boom", commandName: "boom"))
        // 沒有 hook 可呼叫，這裡能跑到這行沒被 fatalError／crash 掉，就是驗證通過
    }

    @Test("a throwing onError hook itself doesn't crash dispatch, since the original error is already logged (boundary)")
    func throwingHookDoesNotCrashDispatch() async throws {
        let apiClient = RecordingAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )
        registry.setErrorHandler { _, _ in throw BoomError() }

        let scene = Scene<State, EmptySession>(name: "boom", initial: .only)
        scene.on(.only) { _ in throw BoomError() }
        registry.registerScene(scene, commandTrigger: "boom")

        await engine.dispatch(update: Update(updateID: 1, chatID: 42, text: "/boom", commandName: "boom"))
        // hook 自己也丟錯，dispatch 不該被拖垮，能跑到這裡就是驗證通過
    }
}
