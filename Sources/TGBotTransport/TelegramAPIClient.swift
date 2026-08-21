import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

/// Inline keyboard 按鈕的 Transport 層原始表示。開發者實際會用的 `InlineButton`
/// 定義在 TGBotConversation（見架構設計文件第 8 節「選單整合」，那是它的職責範圍），
/// 但 TGBotTransport 不能反過來依賴 TGBotConversation（會形成循環依賴，跟先前
/// JobResult 撞到的問題同一類），所以這裡另外定義一個更底層、Transport 自己夠用的版本，
/// 由 GlobalContext.replyWithMenu 負責把 [InlineButton] 轉換成這個型別再往下傳。
public struct TGInlineKeyboardButton: Sendable {
    public let text: String
    public let callbackData: String

    public init(text: String, callbackData: String) {
        self.text = text
        self.callbackData = callbackData
    }
}

/// sendMessage 的文字格式化模式，對應 Telegram Bot API 的 parse_mode 參數。
/// 不帶（nil）就是純文字，跟原本行為一致。
public enum TGParseMode: String, Sendable, Equatable {
    case html = "HTML"
    case markdown = "Markdown"
    case markdownV2 = "MarkdownV2"
}

/// sendPhoto／sendDocument 要送出的檔案內容來源。三種都對應 Telegram Bot API 本身
/// 就支援的送法：.fileID 重用已經上傳過的檔案（最省流量，例如轉發使用者剛傳來的
/// 照片）；.url 讓 Telegram 伺服器自己去抓公開網址；.data 是真正把本地端的檔案
/// bytes 上傳上去（沒有現成 file_id／URL 時唯一的選項），走 multipart/form-data。
public enum TGFileSource: Sendable {
    case fileID(String)
    case url(String)
    case data(Data, filename: String, mimeType: String)
}

/// 對外呼叫 Telegram Bot API 的能力。一次性呼叫（如 sendMessage）依 4.1 節規則不重試，
/// 失敗直接 throw，交由呼叫端（最終是 6.5 節的錯誤處理路徑）決定要不要通知使用者或自己重送。
public protocol TelegramAPIClient: Sendable {
    func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws
    /// 帶 parse_mode 的版本，讓 sendMessage 也能送 HTML/Markdown（例如可點擊連結）。
    /// 獨立的 protocol requirement 而非只用 extension 預設值，是因為透過 `TelegramAPIClient`
    /// 介面型別（例如 GlobalContext 持有的 apiClient）呼叫時，non-requirement 的 extension
    /// method 是靜態綁定、不會呼叫到具體型別（如 URLSessionTelegramAPIClient）自己的覆寫版本
    /// ——parse_mode 會被靜靜吃掉、永遠送不出去。獨立列成 requirement 才能確保動態派發正確。
    /// 有預設實作（見下方 extension），既有的 fake 不用跟著改。
    func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?, parseMode: TGParseMode?) async throws
    /// 再帶 disable_web_page_preview 的版本，讓連結不要自動展開成預覽卡片（例如訊息裡
    /// 有多個連結、或連結只是附帶提及、不想讓卡片喧賓奪主的時候）。跟 parseMode 版本
    /// 同樣的理由獨立列成 requirement，不能只靠 extension 預設值，見上一個 requirement
    /// 的說明——不然透過 `TelegramAPIClient` 介面型別呼叫時會永遠打到忽略這個參數的版本。
    func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?, parseMode: TGParseMode?, disableWebPagePreview: Bool) async throws
    func getUpdates(offset: Int?, timeout: Int) async throws -> [Update]
    func setMyCommands(_ commands: [(name: String, description: String)]) async throws
    /// Telegram 規定收到 callback_query 後要呼叫這個確認收到，不然使用者端的按鈕會一直
    /// 卡在「處理中」的視覺狀態——即使機器人其實已經正常處理完、也回了新訊息。
    /// text 是可選的小提示（會用 toast 顯示在使用者畫面上），大多數情況不需要，見 extension 的語法糖版本。
    func answerCallbackQuery(callbackQueryID: String, text: String?) async throws

    /// 拿掉指定訊息上的 inline keyboard。用在使用者點擊按鈕、流程往下走之後，讓那則舊訊息
    /// 的按鈕不能再被點——不然使用者回頭誤點已經處理過的按鈕，會被目前的對話狀態誤判成
    /// 別的意思，跳出文不對題的回覆。見 ConversationEngine.dispatch。
    func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws

    /// 把指定訊息的文字換成 text。用在開發者想讓「使用者剛剛點的按鈕所在的訊息」順便
    /// 顯示選擇結果的時候，見 GlobalContext.updateOriginalMessage(_:)。
    func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws

    /// 帶 parse_mode 的版本，理由同 sendMessage 的 parseMode 版本。有預設實作（見下方
    /// extension）退回不支援 parse_mode 的版本，既有的 fake 不用跟著改。
    func editMessageText(chatID: Int64, messageID: Int64, text: String, parseMode: TGParseMode?) async throws

    /// 送出照片。獨立列成 requirement（而非只靠 extension）的理由跟 sendMessage 的
    /// parseMode／disableWebPagePreview 版本一樣：透過 `TelegramAPIClient` 介面型別呼叫時，
    /// 非 requirement 的 extension method 是靜態綁定，不會呼叫到 URLSessionTelegramAPIClient
    /// 自己的覆寫版本。這裡沒有「更基本版本」可以委派（是全新能力），下方 extension 給的
    /// 預設實作直接 throw，讓既有的測試用 fake 不用跟著改（反正它們從不呼叫這兩個方法）。
    func sendPhoto(chatID: Int64, photo: TGFileSource, caption: String?) async throws

    /// 帶 parse_mode 的版本，讓照片 caption 也能送 HTML/Markdown。獨立列成 requirement
    /// 的理由跟 sendMessage 的 parseMode 版本一樣（見上方說明），有預設實作（見下方
    /// extension）退回不支援 parse_mode 的版本，既有的 fake 不用跟著改。
    func sendPhoto(chatID: Int64, photo: TGFileSource, caption: String?, parseMode: TGParseMode?) async throws

    /// 送出一般檔案，理由同 sendPhoto。
    func sendDocument(chatID: Int64, document: TGFileSource, caption: String?) async throws

    /// 帶 parse_mode 的版本，理由同 sendPhoto 的 parseMode 版本。
    func sendDocument(chatID: Int64, document: TGFileSource, caption: String?, parseMode: TGParseMode?) async throws

    /// 用 file_id 換取可以組出下載網址的 file_path（Telegram Bot API 的兩段式下載流程，
    /// 見 downloadFile(filePath:) 的說明）。
    func getFile(fileID: String) async throws -> String

    /// 用 getFile 拿到的 file_path 下載檔案原始內容。這條路徑走的是另一個網域
    /// （api.telegram.org/file/...），回應不是 TGResponse JSON envelope，是檔案本身的 bytes。
    func downloadFile(filePath: String) async throws -> Data
}

extension TelegramAPIClient {
    /// 不帶按鈕的純文字訊息，語法糖版本，protocol 本身不能給預設參數值，用 extension 補上。
    public func sendMessage(chatID: Int64, text: String) async throws {
        try await sendMessage(chatID: chatID, text: text, inlineKeyboard: nil)
    }

    /// 不帶按鈕、但要指定 parse_mode 的版本。
    public func sendMessage(chatID: Int64, text: String, parseMode: TGParseMode?) async throws {
        try await sendMessage(chatID: chatID, text: text, inlineKeyboard: nil, parseMode: parseMode)
    }

    /// 帶 parseMode 版本的預設實作：沒有另外覆寫的型別（多半是測試用的 fake）直接退回
    /// 不支援 parse_mode 的舊版 sendMessage，parseMode 會被忽略——對只在乎「訊息有沒有送出」
    /// 的測試來說沒有差別，真正會送出 parse_mode 的只有 URLSessionTelegramAPIClient 自己的覆寫版本。
    public func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?, parseMode: TGParseMode?) async throws {
        try await sendMessage(chatID: chatID, text: text, inlineKeyboard: inlineKeyboard)
    }

    /// 不帶按鈕、但要指定 parseMode／disableWebPagePreview 的版本。
    public func sendMessage(chatID: Int64, text: String, parseMode: TGParseMode?, disableWebPagePreview: Bool) async throws {
        try await sendMessage(chatID: chatID, text: text, inlineKeyboard: nil, parseMode: parseMode, disableWebPagePreview: disableWebPagePreview)
    }

    /// 帶 disableWebPagePreview 版本的預設實作：退回帶 parseMode 的版本，disableWebPagePreview
    /// 被忽略——原因跟上面 parseMode 那個預設實作一樣，只影響沒有另外覆寫的型別（測試 fake）。
    public func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?, parseMode: TGParseMode?, disableWebPagePreview: Bool) async throws {
        try await sendMessage(chatID: chatID, text: text, inlineKeyboard: inlineKeyboard, parseMode: parseMode)
    }

    /// 不帶提示文字的版本，絕大多數情況只是要「確認收到」，用這個就夠了。
    public func answerCallbackQuery(callbackQueryID: String) async throws {
        try await answerCallbackQuery(callbackQueryID: callbackQueryID, text: nil)
    }

    /// 不帶 caption 的版本，語法糖。
    public func sendPhoto(chatID: Int64, photo: TGFileSource) async throws {
        try await sendPhoto(chatID: chatID, photo: photo, caption: nil)
    }

    /// 不帶 caption 的版本，語法糖。
    public func sendDocument(chatID: Int64, document: TGFileSource) async throws {
        try await sendDocument(chatID: chatID, document: document, caption: nil)
    }

    /// 帶 parseMode 版本的預設實作：沒有另外覆寫的型別（多半是測試用的 fake）退回
    /// 不支援 parse_mode 的版本，parseMode 會被忽略——跟 sendMessage 那組預設實作同一個理由。
    public func editMessageText(chatID: Int64, messageID: Int64, text: String, parseMode: TGParseMode?) async throws {
        try await editMessageText(chatID: chatID, messageID: messageID, text: text)
    }

    /// sendPhoto／sendDocument／getFile／downloadFile(filePath:) 的預設實作：沒有另外
    /// 覆寫的型別（多半是測試用的 fake）直接 throw——這幾個是全新能力，沒有「更基本版本」
    /// 可以退回，跟 sendMessage 那組預設實作（退回不支援新參數的舊版）不一樣。對只在乎
    /// 既有功能的測試 fake 來說沒有影響，因為它們的測試從不呼叫這幾個方法；真正會用到的
    /// 只有 URLSessionTelegramAPIClient 自己的覆寫版本。
    public func sendPhoto(chatID: Int64, photo: TGFileSource, caption: String?) async throws {
        throw TelegramAPIError.apiError("sendPhoto is not supported by this TelegramAPIClient")
    }

    /// 帶 parseMode 版本的預設實作：沒有另外覆寫的型別（多半是測試用的 fake）退回
    /// 不支援 parse_mode 的版本，parseMode 會被忽略——跟 sendMessage 那組預設實作同一個理由。
    public func sendPhoto(chatID: Int64, photo: TGFileSource, caption: String?, parseMode: TGParseMode?) async throws {
        try await sendPhoto(chatID: chatID, photo: photo, caption: caption)
    }

    public func sendDocument(chatID: Int64, document: TGFileSource, caption: String?) async throws {
        throw TelegramAPIError.apiError("sendDocument is not supported by this TelegramAPIClient")
    }

    /// 帶 parseMode 版本的預設實作，理由同 sendPhoto 的 parseMode 版本。
    public func sendDocument(chatID: Int64, document: TGFileSource, caption: String?, parseMode: TGParseMode?) async throws {
        try await sendDocument(chatID: chatID, document: document, caption: caption)
    }

    public func getFile(fileID: String) async throws -> String {
        throw TelegramAPIError.apiError("getFile is not supported by this TelegramAPIClient")
    }

    public func downloadFile(filePath: String) async throws -> Data {
        throw TelegramAPIError.apiError("downloadFile is not supported by this TelegramAPIClient")
    }

    /// getFile + downloadFile(filePath:) 兩步驟包成一步的語法糖，對應開發者實際想做的事：
    /// 「給我 file_id，我要那個檔案的內容」，不用自己記得 Telegram 這邊是兩段式流程。
    public func downloadFile(fileID: String) async throws -> Data {
        let filePath = try await getFile(fileID: fileID)
        return try await downloadFile(filePath: filePath)
    }
}

/// v1 實作，使用 URLSession（見架構設計文件第 13 節「Transport 實作技術」決策與 13.1 節實測記錄）。
public final class URLSessionTelegramAPIClient: TelegramAPIClient, @unchecked Sendable {
    private let token: String
    private let session: URLSession
    private let logger: Logger
    private let baseURL: String

    public init(token: String, session: URLSession = .shared, logger: Logger = Logger(label: "TGBotTransport")) {
        self.token = token
        self.session = session
        self.logger = logger
        self.baseURL = "https://api.telegram.org/bot\(token)"
    }

    public func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
        try await sendMessage(chatID: chatID, text: text, inlineKeyboard: inlineKeyboard, parseMode: nil)
    }

    public func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?, parseMode: TGParseMode?) async throws {
        try await sendMessage(chatID: chatID, text: text, inlineKeyboard: inlineKeyboard, parseMode: parseMode, disableWebPagePreview: false)
    }

    public func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?, parseMode: TGParseMode?, disableWebPagePreview: Bool) async throws {
        struct InlineKeyboardButtonBody: Encodable {
            let text: String
            let callbackData: String
            enum CodingKeys: String, CodingKey {
                case text
                case callbackData = "callback_data"
            }
        }
        struct ReplyMarkup: Encodable {
            let inlineKeyboard: [[InlineKeyboardButtonBody]]
            enum CodingKeys: String, CodingKey {
                case inlineKeyboard = "inline_keyboard"
            }
        }
        struct Body: Encodable {
            let chatID: Int64
            let text: String
            let parseMode: String?
            // 故意用 Bool? 而不是 Bool：false 是 Telegram 的預設行為，帶 false 上去
            // 跟完全不帶這個欄位效果一樣，索性 false 時就不編碼這個 key，跟 parseMode
            // 為 nil 時不帶 parse_mode key 是同一種做法，body 保持最小、也方便測試斷言。
            let disableWebPagePreview: Bool?
            let replyMarkup: ReplyMarkup?
            enum CodingKeys: String, CodingKey {
                case chatID = "chat_id"
                case text
                case parseMode = "parse_mode"
                case disableWebPagePreview = "disable_web_page_preview"
                case replyMarkup = "reply_markup"
            }
        }

        let replyMarkup = inlineKeyboard.map { rows in
            ReplyMarkup(inlineKeyboard: rows.map { row in
                row.map { InlineKeyboardButtonBody(text: $0.text, callbackData: $0.callbackData) }
            })
        }

        _ = try await post(
            path: "sendMessage",
            body: Body(
                chatID: chatID,
                text: text,
                parseMode: parseMode?.rawValue,
                disableWebPagePreview: disableWebPagePreview ? true : nil,
                replyMarkup: replyMarkup
            ),
            responseType: TGMessage.self
        )
    }

    public func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] {
        var components = URLComponents(string: "\(baseURL)/getUpdates")!
        // 明確指定 allowed_updates：Telegram 會把「上一次呼叫帶的 allowed_updates」記在
        // bot token 上，之後所有呼叫（不管是誰打的）都會沿用那個過濾設定，直到有人再帶一次
        // 不同的值為止。如果完全不帶這個參數（原本的寫法），一旦任何工具或舊測試曾經帶過
        // 不含 callback_query 的 allowed_updates，就會讓按鈕永遠收不到 callback_query，
        // 而且完全不會報錯、看起來像是「按了沒反應」——這是實機測試才挖出來的真實問題，
        // 單元測試用的假 API client 從來不會踩到（因為根本不會真的呼叫 Telegram）。
        // 固定帶上完整清單，讓 library 的行為不會被外部呼叫過的殘留設定汙染。
        let allowedUpdatesJSON = #"["message","callback_query"]"#
        var queryItems = [
            URLQueryItem(name: "timeout", value: String(timeout)),
            URLQueryItem(name: "allowed_updates", value: allowedUpdatesJSON),
        ]
        if let offset {
            queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        // 長輪詢的 HTTP 逾時要比 Telegram 端的 timeout 參數更寬鬆，避免 URLSession 提早切斷連線
        request.timeoutInterval = TimeInterval(timeout + 10)

        let rawUpdates = try await send(request, responseType: [TGUpdate].self)
        return rawUpdates.map(Update.init(from:))
    }

    public func setMyCommands(_ commands: [(name: String, description: String)]) async throws {
        struct Command: Encodable {
            let command: String
            let description: String
        }
        struct Body: Encodable {
            let commands: [Command]
        }
        let body = Body(commands: commands.map { Command(command: $0.name, description: $0.description) })
        _ = try await post(path: "setMyCommands", body: body, responseType: Bool.self)
    }

    public func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {
        struct Body: Encodable {
            let callbackQueryID: String
            let text: String?
            enum CodingKeys: String, CodingKey {
                case callbackQueryID = "callback_query_id"
                case text
            }
        }
        _ = try await post(
            path: "answerCallbackQuery",
            body: Body(callbackQueryID: callbackQueryID, text: text),
            responseType: Bool.self
        )
    }

    public func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws {
        struct Body: Encodable {
            let chatID: Int64
            let messageID: Int64
            enum CodingKeys: String, CodingKey {
                case chatID = "chat_id"
                case messageID = "message_id"
            }
        }
        // 故意不帶 reply_markup 欄位：Telegram 收到沒有這個欄位的 editMessageReplyMarkup
        // 會直接把整個 inline keyboard 拿掉，正是這裡要的效果（讓按鈕消失、不能再被點）。
        _ = try await post(
            path: "editMessageReplyMarkup",
            body: Body(chatID: chatID, messageID: messageID),
            responseType: TGMessage.self
        )
    }

    public func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws {
        try await editMessageText(chatID: chatID, messageID: messageID, text: text, parseMode: nil)
    }

    public func editMessageText(chatID: Int64, messageID: Int64, text: String, parseMode: TGParseMode?) async throws {
        struct Body: Encodable {
            let chatID: Int64
            let messageID: Int64
            let text: String
            let parseMode: String?
            enum CodingKeys: String, CodingKey {
                case chatID = "chat_id"
                case messageID = "message_id"
                case text
                case parseMode = "parse_mode"
            }
        }
        // 故意不帶 reply_markup：editMessageText 沒帶這個欄位時，Telegram 不會動原本的
        // inline keyboard——但在框架的呼叫順序裡，這個方法一定是在 dispatch 已經先呼叫過
        // editMessageReplyMarkup（拿掉按鈕）之後才可能被開發者呼叫，所以此時反正已經沒有
        // keyboard 了，不用特別再處理一次。
        _ = try await post(
            path: "editMessageText",
            body: Body(chatID: chatID, messageID: messageID, text: text, parseMode: parseMode?.rawValue),
            responseType: TGMessage.self
        )
    }

    public func sendPhoto(chatID: Int64, photo: TGFileSource, caption: String?) async throws {
        try await sendPhoto(chatID: chatID, photo: photo, caption: caption, parseMode: nil)
    }

    public func sendPhoto(chatID: Int64, photo: TGFileSource, caption: String?, parseMode: TGParseMode?) async throws {
        switch photo {
        case .fileID(let value), .url(let value):
            struct Body: Encodable {
                let chatID: Int64
                let photo: String
                let caption: String?
                let parseMode: String?
                enum CodingKeys: String, CodingKey {
                    case chatID = "chat_id"
                    case photo
                    case caption
                    case parseMode = "parse_mode"
                }
            }
            _ = try await post(
                path: "sendPhoto",
                body: Body(chatID: chatID, photo: value, caption: caption, parseMode: parseMode?.rawValue),
                responseType: TGMessage.self
            )
        case .data(let data, let filename, let mimeType):
            _ = try await postMultipart(
                path: "sendPhoto",
                fields: ["chat_id": String(chatID), "caption": caption, "parse_mode": parseMode?.rawValue].compactMapValues { $0 },
                fileField: "photo",
                filename: filename,
                mimeType: mimeType,
                fileData: data,
                responseType: TGMessage.self
            )
        }
    }

    public func sendDocument(chatID: Int64, document: TGFileSource, caption: String?) async throws {
        try await sendDocument(chatID: chatID, document: document, caption: caption, parseMode: nil)
    }

    public func sendDocument(chatID: Int64, document: TGFileSource, caption: String?, parseMode: TGParseMode?) async throws {
        switch document {
        case .fileID(let value), .url(let value):
            struct Body: Encodable {
                let chatID: Int64
                let document: String
                let caption: String?
                let parseMode: String?
                enum CodingKeys: String, CodingKey {
                    case chatID = "chat_id"
                    case document
                    case caption
                    case parseMode = "parse_mode"
                }
            }
            _ = try await post(
                path: "sendDocument",
                body: Body(chatID: chatID, document: value, caption: caption, parseMode: parseMode?.rawValue),
                responseType: TGMessage.self
            )
        case .data(let data, let filename, let mimeType):
            _ = try await postMultipart(
                path: "sendDocument",
                fields: ["chat_id": String(chatID), "caption": caption, "parse_mode": parseMode?.rawValue].compactMapValues { $0 },
                fileField: "document",
                filename: filename,
                mimeType: mimeType,
                fileData: data,
                responseType: TGMessage.self
            )
        }
    }

    public func getFile(fileID: String) async throws -> String {
        struct Body: Encodable {
            let fileID: String
            enum CodingKeys: String, CodingKey {
                case fileID = "file_id"
            }
        }
        let file = try await post(path: "getFile", body: Body(fileID: fileID), responseType: TGFile.self)
        guard let filePath = file.filePath else {
            throw TelegramAPIError.apiError("getFile returned no file_path for file_id \(fileID)")
        }
        return filePath
    }

    public func downloadFile(filePath: String) async throws -> Data {
        // 下載走的是另一個網域（api.telegram.org/file/...），不是 api.telegram.org/bot.../...，
        // 跟其他方法共用的 baseURL 組不出這個網址，這裡另外組。
        let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)")!
        return try await sendRaw(URLRequest(url: url))
    }

    // MARK: - 內部共用邏輯

    private func post<Body: Encodable, Result: Codable & Sendable>(
        path: String,
        body: Body,
        responseType: Result.Type
    ) async throws -> Result {
        var request = URLRequest(url: URL(string: "\(baseURL)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, responseType: responseType)
    }

    /// sendPhoto／sendDocument 的 .data(...) case 用，把純文字欄位跟一個檔案組成
    /// multipart/form-data body——Telegram 收本地端上傳的檔案內容只吃這個格式，JSON
    /// body（post(...) 那條路）沒辦法帶原始 bytes。boundary 用 UUID 確保不會跟檔案
    /// 內容裡剛好出現的位元組序列撞在一起。
    private func postMultipart<Result: Codable & Sendable>(
        path: String,
        fields: [String: String],
        fileField: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        responseType: Result.Type
    ) async throws -> Result {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "\(baseURL)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request, responseType: responseType)
    }

    private func send<Result: Codable & Sendable>(
        _ request: URLRequest,
        responseType: Result.Type
    ) async throws -> Result {
        let data = try await rawResponseData(for: request)
        let decoded = try JSONDecoder().decode(TGResponse<Result>.self, from: data)
        guard decoded.ok, let result = decoded.result else {
            throw TelegramAPIError.apiError(decoded.description ?? "Telegram API returned ok=false")
        }
        return result
    }

    /// downloadFile(filePath:) 用：跟 send(...) 共用「打請求、檢查 HTTP 狀態碼」這段，
    /// 但檔案下載端點回的不是 TGResponse JSON envelope，是檔案本身的原始 bytes，
    /// 不能套用 send(...) 那段解碼邏輯。
    private func sendRaw(_ request: URLRequest) async throws -> Data {
        try await rawResponseData(for: request)
    }

    private func rawResponseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TelegramAPIError.httpError(statusCode: -1, body: "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TelegramAPIError.httpError(statusCode: http.statusCode, body: body)
        }
        return data
    }
}
