import Foundation

/// Telegram Update 的最小化表示。目前只涵蓋文字訊息與 callback_query，
/// 完整的 Telegram Bot API model 待 Transport 層網路實作階段擴充。
public struct Update: Sendable {
    public let updateID: Int64
    public let chatID: Int64
    public let userID: Int64?
    public let text: String?
    public let callbackData: String?
    public let commandName: String?

    /// 只有 callback_query 類型的 Update 才會有值。Telegram 規定收到 callback_query 後
    /// 要呼叫 answerCallbackQuery 確認收到，不然按鈕在使用者端會一直卡在「處理中」
    /// ——這個欄位就是用來讓框架能自動做這件事，開發者不需要自己管。
    public let callbackQueryID: String?

    public init(
        updateID: Int64 = 0,
        chatID: Int64,
        userID: Int64? = nil,
        text: String? = nil,
        callbackData: String? = nil,
        commandName: String? = nil,
        callbackQueryID: String? = nil
    ) {
        self.updateID = updateID
        self.chatID = chatID
        self.userID = userID
        self.text = text
        self.callbackData = callbackData
        self.commandName = commandName
        self.callbackQueryID = callbackQueryID
    }
}
