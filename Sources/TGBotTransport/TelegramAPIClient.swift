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
        struct Body: Encodable {
            let chatID: Int64
            let messageID: Int64
            let text: String
            enum CodingKeys: String, CodingKey {
                case chatID = "chat_id"
                case messageID = "message_id"
                case text
            }
        }
        // 故意不帶 reply_markup：editMessageText 沒帶這個欄位時，Telegram 不會動原本的
        // inline keyboard——但在框架的呼叫順序裡，這個方法一定是在 dispatch 已經先呼叫過
        // editMessageReplyMarkup（拿掉按鈕）之後才可能被開發者呼叫，所以此時反正已經沒有
        // keyboard 了，不用特別再處理一次。
        _ = try await post(
            path: "editMessageText",
            body: Body(chatID: chatID, messageID: messageID, text: text),
            responseType: TGMessage.self
        )
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

    private func send<Result: Codable & Sendable>(
        _ request: URLRequest,
        responseType: Result.Type
    ) async throws -> Result {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TelegramAPIError.httpError(statusCode: -1, body: "no HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TelegramAPIError.httpError(statusCode: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(TGResponse<Result>.self, from: data)
        guard decoded.ok, let result = decoded.result else {
            throw TelegramAPIError.apiError(decoded.description ?? "Telegram API returned ok=false")
        }
        return result
    }
}
