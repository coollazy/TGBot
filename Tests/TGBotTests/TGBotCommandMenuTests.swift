import Testing
import TGBotTransport
import TGBotConversation
@testable import TGBot

/// 這裡守住一個實機測試才發現的真實 bug：register(_:trigger:) 原本沒有 description
/// 參數，用它啟動的 scene（例如 /profile）永遠不會同步進 Telegram 的「/」指令選單，
/// 即使指令本身完全可以正常觸發也一樣。修法是幫 register(_:trigger:) 也加上
/// description 參數。這裡驗證：有給 description 的 register 呼叫、跟 onCommand 一樣
/// 會被 setMyCommands 同步；沒給的話則不會（記錄舊行為，避免以後又被誤解成 bug）。
@Suite("TGBot command menu sync")
struct TGBotCommandMenuTests {
    enum State: ConversationState { case only }

    final class FakeUpdateSource: UpdateSource, @unchecked Sendable {
        // run() 只是要驗證 setMyCommands 有沒有被正確呼叫，不需要真的模擬輪詢迴圈
        func start(onUpdate: @escaping @Sendable (Update) async -> Void) async throws {}
        func stop() async {}
    }

    final class RecordingAPIClient: TelegramAPIClient, @unchecked Sendable {
        private(set) var syncedCommands: [(name: String, description: String)] = []
        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {}
        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {
            syncedCommands = commands
        }
    }

    @Test("register(_:trigger:description:) syncs to setMyCommands just like onCommand(...) does (inside)")
    func registerWithDescriptionSyncsToMenu() async throws {
        let apiClient = RecordingAPIClient()
        let bot = TGBot(
            configuration: .init(token: "test-token"),
            updateSource: FakeUpdateSource(),
            apiClient: apiClient
        )

        let scene = Scene<State, EmptySession>(name: "profile", initial: .only)
        bot.register(scene, trigger: .command("profile"), description: "開始填寫個人資料")
        bot.onCommand("cancel", description: "取消目前進行中的流程") { _ in }

        try await bot.run()

        let names = apiClient.syncedCommands.map(\.name)
        #expect(names.contains("profile"))
        #expect(names.contains("cancel"))
    }

    @Test("register(_:trigger:) without a description is omitted from the menu, but that's opt-in not a bug (boundary)")
    func registerWithoutDescriptionOmittedFromMenu() async throws {
        let apiClient = RecordingAPIClient()
        let bot = TGBot(
            configuration: .init(token: "test-token"),
            updateSource: FakeUpdateSource(),
            apiClient: apiClient
        )

        let scene = Scene<State, EmptySession>(name: "silent", initial: .only)
        bot.register(scene, trigger: .command("silent"))

        try await bot.run()

        #expect(!apiClient.syncedCommands.map(\.name).contains("silent"))
    }

    @Test("no commands with descriptions registered at all: setMyCommands is never called (outside)")
    func noDescriptionsMeansNoSyncCall() async throws {
        let apiClient = RecordingAPIClient()
        let bot = TGBot(
            configuration: .init(token: "test-token"),
            updateSource: FakeUpdateSource(),
            apiClient: apiClient
        )

        let scene = Scene<State, EmptySession>(name: "silent", initial: .only)
        bot.register(scene, trigger: .command("silent"))

        try await bot.run()

        #expect(apiClient.syncedCommands.isEmpty)
    }
}
