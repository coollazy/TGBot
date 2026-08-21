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

struct TGPhotoSize: Codable, Sendable {
    let fileID: String
    let fileUniqueID: String
    let width: Int
    let height: Int
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case width
        case height
        case fileSize = "file_size"
    }
}

struct TGDocument: Codable, Sendable {
    let fileID: String
    let fileUniqueID: String
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

/// getFile API 的回應 model。file_path 拿到手才能組出下載用的 URL；沒有值代表這個
/// file_id 已經過期或不可下載（Telegram 的行為），交由呼叫端決定要不要 throw。
struct TGFile: Codable, Sendable {
    let fileID: String
    let fileUniqueID: String
    let fileSize: Int?
    let filePath: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case fileSize = "file_size"
        case filePath = "file_path"
    }
}

struct TGMessage: Codable, Sendable {
    let messageID: Int64
    let from: TGUser?
    let chat: TGChat
    let text: String?
    let photo: [TGPhotoSize]?
    let document: TGDocument?

    // photo／document 給預設值 nil：既有測試用 memberwise init 建立 TGMessage 時只帶
    // messageID/from/chat/text 四個欄位，加預設值才不用全部改成要多帶兩個 nil。
    init(messageID: Int64, from: TGUser?, chat: TGChat, text: String?, photo: [TGPhotoSize]? = nil, document: TGDocument? = nil) {
        self.messageID = messageID
        self.from = from
        self.chat = chat
        self.text = text
        self.photo = photo
        self.document = document
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case text
        case photo
        case document
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
        let messageID: Int64?
        let photo: IncomingFile?
        let document: IncomingFile?

        if let message = raw.message {
            chatID = message.chat.id
            userID = message.from?.id
            text = message.text
            callbackData = nil
            callbackQueryID = nil
            messageID = message.messageID
            // Telegram 把同一張照片的多種尺寸都放進陣列、由小到大排序，最後一個是最大張。
            // 開發者通常只在意「使用者傳的那張照片」，不需要自己每次都去挑陣列，所以框架
            // 直接幫忙選好最大尺寸（下載時品質最好）。
            photo = message.photo?.last.map {
                IncomingFile(fileID: $0.fileID, fileSize: $0.fileSize)
            }
            document = message.document.map {
                IncomingFile(fileID: $0.fileID, fileName: $0.fileName, mimeType: $0.mimeType, fileSize: $0.fileSize)
            }
        } else if let callbackQuery = raw.callbackQuery {
            chatID = callbackQuery.message?.chat.id ?? 0
            userID = callbackQuery.from.id
            text = nil
            callbackData = callbackQuery.data
            callbackQueryID = callbackQuery.id
            messageID = callbackQuery.message?.messageID
            photo = nil
            document = nil
        } else {
            chatID = 0
            userID = nil
            text = nil
            callbackData = nil
            callbackQueryID = nil
            messageID = nil
            photo = nil
            document = nil
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
            callbackQueryID: callbackQueryID,
            messageID: messageID,
            photo: photo,
            document: document
        )
    }
}
