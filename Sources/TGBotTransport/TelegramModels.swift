import Foundation

/// Telegram Bot API 的原始 JSON model，僅涵蓋 echo bot 垂直切片需要的欄位
/// （文字訊息、callback_query）。完整涵蓋所有 update 型別待後續擴充。

struct TGUser: Codable, Sendable {
    let id: Int64
    let isBot: Bool
    let firstName: String

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
    }
}

struct TGChat: Codable, Sendable {
    let id: Int64
}

struct TGMessage: Codable, Sendable {
    let messageID: Int64
    let from: TGUser?
    let chat: TGChat
    let text: String?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case text
    }
}

struct TGCallbackQuery: Codable, Sendable {
    let id: String
    let from: TGUser
    let message: TGMessage?
    let data: String?
}

struct TGUpdate: Codable, Sendable {
    let updateID: Int64
    let message: TGMessage?
    let callbackQuery: TGCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

struct TGResponse<T: Codable & Sendable>: Codable, Sendable {
    let ok: Bool
    let result: T?
    let description: String?
    let errorCode: Int?

    enum CodingKeys: String, CodingKey {
        case ok, result, description
        case errorCode = "error_code"
    }
}

public enum TelegramAPIError: Error, Sendable {
    case httpError(statusCode: Int, body: String)
    case apiError(String)
}

extension Update {
    /// 把 Telegram 原始 Update 映射成 TGBot 對外的簡化表示。
    /// commandName：文字以 "/" 開頭時，取第一個 token（去掉 "/" 與可能的 "@botname" 後綴）。
    init(from raw: TGUpdate) {
        let chatID: Int64
        let userID: Int64?
        let text: String?
        let callbackData: String?
        let callbackQueryID: String?

        if let message = raw.message {
            chatID = message.chat.id
            userID = message.from?.id
            text = message.text
            callbackData = nil
            callbackQueryID = nil
        } else if let callbackQuery = raw.callbackQuery {
            chatID = callbackQuery.message?.chat.id ?? 0
            userID = callbackQuery.from.id
            text = nil
            callbackData = callbackQuery.data
            callbackQueryID = callbackQuery.id
        } else {
            chatID = 0
            userID = nil
            text = nil
            callbackData = nil
            callbackQueryID = nil
        }

        var commandName: String?
        if let text, text.hasPrefix("/") {
            let firstToken = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
            let withoutSlash = firstToken.dropFirst()
            commandName = String(withoutSlash.split(separator: "@").first ?? Substring(withoutSlash))
        }

        self.init(
            updateID: raw.updateID,
            chatID: chatID,
            userID: userID,
            text: text,
            callbackData: callbackData,
            commandName: commandName,
            callbackQueryID: callbackQueryID
        )
    }
}
