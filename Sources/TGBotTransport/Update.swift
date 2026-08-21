import Foundation

/// 使用者傳來的照片或檔案的簡化表示。photo 跟 document 都用這個型別，差別只在
/// fileName／mimeType 是否有值（photo 是 Telegram 自動產生的縮圖尺寸，沒有檔名可言）。
public struct IncomingFile: Sendable {
    public let fileID: String
    public let fileName: String?
    public let mimeType: String?
    public let fileSize: Int?

    public init(fileID: String, fileName: String? = nil, mimeType: String? = nil, fileSize: Int? = nil) {
        self.fileID = fileID
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileSize = fileSize
    }
}

/// Telegram Update 的最小化表示。目前只涵蓋文字訊息、callback_query、照片與檔案，
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

    /// 這則 update 對應到的訊息 ID：文字訊息是那則訊息本身，callback_query 則是「按鈕
    /// 所在的那則訊息」。框架用它在收到按鈕點擊後自動把按鈕拿掉（editMessageReplyMarkup），
    /// 避免使用者回頭誤點已經處理過的舊按鈕、跟目前對話狀態對不上而出現莫名其妙的回覆。
    public let messageID: Int64?

    /// 使用者傳來的照片（取最大尺寸那張，見 Update.init(from:) 的映射邏輯）。
    public let photo: IncomingFile?

    /// 使用者傳來的一般檔案。
    public let document: IncomingFile?

    public init(
        updateID: Int64 = 0,
        chatID: Int64,
        userID: Int64? = nil,
        text: String? = nil,
        callbackData: String? = nil,
        commandName: String? = nil,
        callbackQueryID: String? = nil,
        messageID: Int64? = nil,
        photo: IncomingFile? = nil,
        document: IncomingFile? = nil
    ) {
        self.updateID = updateID
        self.chatID = chatID
        self.userID = userID
        self.text = text
        self.callbackData = callbackData
        self.commandName = commandName
        self.callbackQueryID = callbackQueryID
        self.messageID = messageID
        self.photo = photo
        self.document = document
    }
}
