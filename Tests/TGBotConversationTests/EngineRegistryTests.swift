import Testing
import Foundation
import Logging
import TGBotTransport
@testable import TGBotConversation

/// EngineRegistry 是 scene／指令的查找表，7 個對外方法先前完全沒被直接單元測試過
/// （只間接透過 registerScene 被 echo 測試碰到）。這裡把查找的正常情況、查不到的情況、
/// 「還沒註冊任何東西」這個邊界都補上。
@Suite("EngineRegistry")
struct EngineRegistryTests {
    enum State: ConversationState { case only }

    final class NoOpAPIClient: TelegramAPIClient, @unchecked Sendable {
        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {}
        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
        func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {}
        func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws {}
        func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws {}
    }

    struct NoOpEngineHandle: ConversationEngineHandle {
        func resetConversation(chatID: Int64) async {}
        func registerPendingCompletion(
            chatID: Int64, taskID: String,
            completion: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func deliverBackgroundJobResult(chatID: Int64, taskID: String, result: JobResult) async {}
        func applyBackgroundTransition(
            chatID: Int64, sceneName: String, kind: TransitionKind,
            newStateData: Data?, newSessionData: Data
        ) async {}
    }

    func makeGlobalContext() -> GlobalContext {
        GlobalContext(
            chatID: 1,
            userID: nil,
            text: "/cancel",
            callbackData: nil,
            apiClient: NoOpAPIClient(),
            engine: NoOpEngineHandle(),
            logger: Logger(label: "test")
        )
    }

    @Test("scene(named:) finds a registered scene by its own name (inside)")
    func sceneNamedFound() {
        let registry = EngineRegistry()
        let scene = Scene<State, EmptySession>(name: "demo", initial: .only)
        registry.registerScene(scene, commandTrigger: "start")

        #expect(registry.scene(named: "demo") != nil)
    }

    @Test("scene(named:) returns nil for a name that was never registered (outside)")
    func sceneNamedNotFound() {
        let registry = EngineRegistry()
        #expect(registry.scene(named: "does-not-exist") == nil)
    }

    @Test("scene(forTrigger:) finds the scene by the command that bootstraps it (inside)")
    func sceneForTriggerFound() {
        let registry = EngineRegistry()
        let scene = Scene<State, EmptySession>(name: "demo", initial: .only)
        registry.registerScene(scene, commandTrigger: "start")

        #expect(registry.scene(forTrigger: "start") != nil)
        // trigger 名字和 scene 名字是兩個獨立的命名空間，不應該互相串成一個查詢
        #expect(registry.scene(forTrigger: "demo") == nil)
    }

    // register(_:trigger:) 的 trigger 原本強制必填，逼著「只想被 .interrupt(with:) 中斷
    // 帶進來、不開放使用者直接打指令」的 scene（例如子流程）也要掰一個用不到的指令出去，
    // 不然 scenesByName 沒寫入、撐不過第一輪之後的 dispatch 就會找不到這個 scene。
    // 改成 optional 之後，這裡驗證「沒給 trigger」還是會正確寫進 scenesByName，只是
    // 不會出現在任何指令查詢裡。
    @Test("registerScene with commandTrigger: nil is findable by name but bootstraps no command (inside)")
    func registerSceneWithNilTriggerHasNoCommandEntry() {
        let registry = EngineRegistry()
        let scene = Scene<State, EmptySession>(name: "sub-only", initial: .only)
        registry.registerScene(scene, commandTrigger: nil)

        #expect(registry.scene(named: "sub-only") != nil)
        #expect(registry.scene(forTrigger: "sub-only") == nil)
    }

    @Test("commandHandler(for:) / unhandledHandlerIfAny return nil before anything is registered (boundary: empty registry)")
    func emptyRegistryReturnsNil() {
        let registry = EngineRegistry()
        #expect(registry.commandHandler(for: "cancel") == nil)
        #expect(registry.unhandledHandlerIfAny() == nil)
    }

    /// @Sendable handler 不能直接捕捉、改動測試函式裡的區域 var（Swift 6 嚴格並發檢查
    /// 會擋下來），用一個帶鎖的小 box 代替。
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    @Test("registerCommand overwrites a previous handler registered under the same name")
    func registerCommandOverwrites() async throws {
        let registry = EngineRegistry()
        let callCount = Box(0)
        registry.registerCommand("cancel") { _ in callCount.value += 1 }
        registry.registerCommand("cancel") { _ in callCount.value += 10 }

        let handler = try #require(registry.commandHandler(for: "cancel"))
        try await handler(makeGlobalContext())

        #expect(callCount.value == 10)
    }

    @Test("setUnhandledHandler is retrievable via unhandledHandlerIfAny once set")
    func unhandledHandlerRoundTrips() async throws {
        let registry = EngineRegistry()
        let wasCalled = Box(false)
        registry.setUnhandledHandler { _ in wasCalled.value = true }

        let handler = try #require(registry.unhandledHandlerIfAny())
        try await handler(makeGlobalContext())

        #expect(wasCalled.value)
    }
}
