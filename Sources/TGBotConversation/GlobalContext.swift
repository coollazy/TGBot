import Foundation
import Logging
import TGBotTransport

/// 不綁定特定 scene 的 State/Session、跨所有 handler 通用的基底能力，全域指令
/// （例如 /cancel）拿到的就是這個型別。見架構設計文件 6.1／8.1 節。
public class GlobalContext: @unchecked Sendable {
    public let chatID: Int64
    public let userID: Int64?
    public let text: String?
    public let callbackData: String?

    /// 這次 update 對應的訊息 ID（callback_query 是按鈕所在的那則訊息）。
    /// updateOriginalMessage(_:) 靠它知道要編輯哪一則訊息。
    let messageID: Int64?

    /// 使用者這次傳來的照片／檔案（沒有就是 nil）。開發者要下載內容用 downloadFile(_:)。
    public let photo: IncomingFile?
    public let document: IncomingFile?

    let apiClient: TelegramAPIClient
    let engine: ConversationEngineHandle
    let logger: Logger

    init(
        chatID: Int64,
        userID: Int64?,
        text: String?,
        callbackData: String?,
        messageID: Int64? = nil,
        photo: IncomingFile? = nil,
        document: IncomingFile? = nil,
        apiClient: TelegramAPIClient,
        engine: ConversationEngineHandle,
        logger: Logger
    ) {
        self.chatID = chatID
        self.userID = userID
        self.text = text
        self.callbackData = callbackData
        self.messageID = messageID
        self.photo = photo
        self.document = document
        self.apiClient = apiClient
        self.engine = engine
        self.logger = logger
    }

    public func reply(_ text: String, parseMode: TGParseMode? = nil, disableWebPagePreview: Bool = false) async throws {
        try await apiClient.sendMessage(chatID: chatID, text: text, inlineKeyboard: nil, parseMode: parseMode, disableWebPagePreview: disableWebPagePreview)
    }

    public func replyWithMenu(_ text: String, buttons: [[InlineButton]], parseMode: TGParseMode? = nil, disableWebPagePreview: Bool = false) async throws {
        let rows = buttons.map { row in
            row.map { TGInlineKeyboardButton(text: $0.text, callbackData: $0.callbackData) }
        }
        try await apiClient.sendMessage(chatID: chatID, text: text, inlineKeyboard: rows, parseMode: parseMode, disableWebPagePreview: disableWebPagePreview)
    }

    public func replyWithPhoto(_ source: TGFileSource, caption: String? = nil, parseMode: TGParseMode? = nil) async throws {
        try await apiClient.sendPhoto(chatID: chatID, photo: source, caption: caption, parseMode: parseMode)
    }

    public func replyWithDocument(_ source: TGFileSource, caption: String? = nil, parseMode: TGParseMode? = nil) async throws {
        try await apiClient.sendDocument(chatID: chatID, document: source, caption: caption, parseMode: parseMode)
    }

    /// 下載使用者傳來的照片／檔案內容（ctx.photo／ctx.document 拿到的那個 IncomingFile）。
    public func downloadFile(_ file: IncomingFile) async throws -> Data {
        try await apiClient.downloadFile(fileID: file.fileID)
    }

    /// 把「使用者剛剛點的那個按鈕所在的訊息」文字換成 text（例如把「請選擇性別：」換成
    /// 「請選擇性別：已選擇 男 ✅」）。框架已經自動把按鈕拿掉了（見 ConversationEngine.dispatch），
    /// 這個方法純粹是選配的加值——要不要順便讓使用者看到自己選了什麼、要用什麼字，
    /// 交給開發者自己決定，框架不會自動幫忙組字（callback_data 本身通常是給程式看的內部值，
    /// 例如 "male"，不是給使用者看的中文標籤，框架沒辦法自動生出正確的顯示文字）。
    ///
    /// 只有透過按鈕點擊（callback_query）觸發的 handler 才拿得到 messageID，一般文字訊息
    /// 呼叫這個方法會被忽略（沒有意義：不是「按鈕所在的訊息」）。
    public func updateOriginalMessage(_ text: String, parseMode: TGParseMode? = nil) async throws {
        guard let messageID else { return }
        try await apiClient.editMessageText(chatID: chatID, messageID: messageID, text: text, parseMode: parseMode)
    }

    /// US-5：清空目前 chat 的 scene/state/session/歷史棧/scene 棧，回到 idle。
    /// 不影響 pendingCompletions（背景任務通知），見架構設計文件 6.2／7.1 節。
    public func resetConversation() async {
        await engine.resetConversation(chatID: chatID)
    }
}
