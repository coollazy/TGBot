import Testing
@testable import TGBotTransport

/// Update(from: TGUpdate) 有實際的字串處理邏輯（指令名稱解析：去掉開頭的 "/"、
/// 去掉可能的 "@botname" 後綴），先前完全沒被驗證過，純函式不需要碰網路。
@Suite("Update(from: TGUpdate) mapping")
struct UpdateMappingTests {
    @Test("plain command text: commandName is parsed without the leading slash (inside)")
    func plainCommand() {
        let raw = TGUpdate(updateID: 1, message: TGMessage(messageID: 1, from: nil, chat: TGChat(id: 42), text: "/echo"), callbackQuery: nil)
        let update = Update(from: raw)
        #expect(update.commandName == "echo")
        #expect(update.text == "/echo")
    }

    @Test("command with @botname suffix: suffix is stripped (boundary: group chat command format)")
    func commandWithBotnameSuffix() {
        let raw = TGUpdate(updateID: 1, message: TGMessage(messageID: 1, from: nil, chat: TGChat(id: 42), text: "/echo@my_bot"), callbackQuery: nil)
        let update = Update(from: raw)
        #expect(update.commandName == "echo")
    }

    @Test("command with trailing arguments: only the first token becomes commandName (boundary)")
    func commandWithArguments() {
        let raw = TGUpdate(updateID: 1, message: TGMessage(messageID: 1, from: nil, chat: TGChat(id: 42), text: "/echo hello world"), callbackQuery: nil)
        let update = Update(from: raw)
        #expect(update.commandName == "echo")
        #expect(update.text == "/echo hello world")
    }

    @Test("plain text without a leading slash: commandName is nil (outside)")
    func plainTextIsNotACommand() {
        let raw = TGUpdate(updateID: 1, message: TGMessage(messageID: 1, from: nil, chat: TGChat(id: 42), text: "hello"), callbackQuery: nil)
        let update = Update(from: raw)
        #expect(update.commandName == nil)
    }

    @Test("nil text (e.g. a sticker message): commandName is nil, no crash (boundary)")
    func nilTextDoesNotCrash() {
        let raw = TGUpdate(updateID: 1, message: TGMessage(messageID: 1, from: nil, chat: TGChat(id: 42), text: nil), callbackQuery: nil)
        let update = Update(from: raw)
        #expect(update.commandName == nil)
        #expect(update.text == nil)
    }

    @Test("callback_query update: chatID/userID/callbackData come from the callback, text is nil (inside)")
    func callbackQueryMapping() {
        let user = TGUser(id: 7, isBot: false, firstName: "A")
        let message = TGMessage(messageID: 1, from: nil, chat: TGChat(id: 42), text: nil)
        let raw = TGUpdate(updateID: 1, message: nil, callbackQuery: TGCallbackQuery(id: "cb1", from: user, message: message, data: "pick-a"))
        let update = Update(from: raw)

        #expect(update.chatID == 42)
        #expect(update.userID == 7)
        #expect(update.callbackData == "pick-a")
        #expect(update.text == nil)
        #expect(update.commandName == nil)
        // callbackQueryID 一定要正確帶出來，answerCallbackQuery 需要靠它才能確認收到
        // （這是實機測試發現「按鈕點了沒反應」才補上的欄位，之前沒有這個 field 可以測）
        #expect(update.callbackQueryID == "cb1")
        // messageID 要從「按鈕所在的那則訊息」取得，不是別的地方——框架靠它事後把
        // 舊按鈕拿掉（editMessageReplyMarkup），拿錯訊息會變成把不相干的訊息改掉
        #expect(update.messageID == 1)
    }

    @Test("a plain message update has no callbackQueryID, but does carry its own messageID (boundary: text path shouldn't try to ack anything)")
    func messageUpdateHasNoCallbackQueryID() {
        let raw = TGUpdate(updateID: 1, message: TGMessage(messageID: 5, from: nil, chat: TGChat(id: 42), text: "hi"), callbackQuery: nil)
        let update = Update(from: raw)
        #expect(update.callbackQueryID == nil)
        #expect(update.messageID == 5)
    }

    @Test("neither message nor callback_query present: falls back to chatID 0, no crash (outside/degenerate)")
    func neitherMessageNorCallback() {
        let raw = TGUpdate(updateID: 1, message: nil, callbackQuery: nil)
        let update = Update(from: raw)
        #expect(update.chatID == 0)
        #expect(update.userID == nil)
    }
}
