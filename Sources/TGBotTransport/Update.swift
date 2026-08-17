import Foundation

/// Telegram Update 的最小化表示。目前只涵蓋文字訊息與 callback_query，
/// 完整的 Telegram Bot API model 待 Transport 層網路實作階段擴充。
public struct Update: Sendable {
    public let chatID: Int64
    public let userID: Int64?
    public let text: String?
    public let callbackData: String?
    public let commandName: String?

    public init(
        chatID: Int64,
        userID: Int64? = nil,
        text: String? = nil,
        callbackData: String? = nil,
        commandName: String? = nil
    ) {
        self.chatID = chatID
        self.userID = userID
        self.text = text
        self.callbackData = callbackData
        self.commandName = commandName
    }
}
