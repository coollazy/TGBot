import Testing
import TGBotTransport
import TGBotAccessControl
import TGBotConversation
@testable import TGBot

/// 對照需求書 US-4 才發現的落差：「名單外的訊息會收到明確的拒絕回覆，而非靜默忽略」
/// 這句話一直沒有真的做到——被 AllowList 擋下的請求，之前只會印一行 debug log，
/// 使用者端什麼都收不到，等於還是靜默忽略。這裡驗證：擋下的請求真的會收到
/// configuration.unauthorizedMessage(...) 產生的文字；允許的請求則正常走 dispatch，
/// 不會誤觸發拒絕回覆。
@Suite("unauthorized access rejection")
struct UnauthorizedAccessTests {
    enum State: ConversationState { case only }

    /// 只送出一筆事先準備好的 Update 給 onUpdate，然後就結束——不需要真的模擬輪詢迴圈。
    final class SingleUpdateSource: UpdateSource, @unchecked Sendable {
        let update: Update
        init(_ update: Update) { self.update = update }
        func start(onUpdate: @escaping @Sendable (Update) async -> Void) async throws {
            await onUpdate(update)
        }
        func stop() async {}
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

    @Test("a request from outside the allow list receives the configured unauthorized reply (inside)")
    func rejectedRequestReceivesUnauthorizedReply() async throws {
        let apiClient = RecordingAPIClient()
        let update = Update(updateID: 1, chatID: 999, userID: 999, text: "hi")
        let bot = TGBot(
            configuration: .init(
                token: "test-token",
                allowList: AllowList(userIDs: [1]), // 只有 user 1 被允許，999 會被擋下
                unauthorizedMessage: { userID, chatID in "你不能用這個 bot（user_id: \(userID ?? -1)）" }
            ),
            updateSource: SingleUpdateSource(update),
            apiClient: apiClient
        )

        try await bot.run()

        #expect(apiClient.sentMessages.count == 1)
        #expect(apiClient.sentMessages[0].chatID == 999)
        #expect(apiClient.sentMessages[0].text == "你不能用這個 bot（user_id: 999）")
    }

    @Test("a request from inside the allow list is dispatched normally, no unauthorized reply (outside)")
    func allowedRequestIsDispatchedNormally() async throws {
        let apiClient = RecordingAPIClient()
        let update = Update(updateID: 1, chatID: 1, userID: 1, text: "/hello", commandName: "hello")
        let bot = TGBot(
            configuration: .init(token: "test-token", allowList: AllowList(userIDs: [1])),
            updateSource: SingleUpdateSource(update),
            apiClient: apiClient
        )
        bot.onCommand("hello") { ctx in
            try await ctx.reply("world")
        }

        try await bot.run()

        #expect(apiClient.sentMessages.count == 1)
        #expect(apiClient.sentMessages[0].text == "world")
    }
}
