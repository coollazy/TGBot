import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TGBotTransport

/// URLSessionTelegramAPIClient 是真正會發 HTTP 請求、編解碼 JSON 的地方，先前完全沒被
/// 驗證過（只驗證過能編譯）。這裡用自訂的 URLProtocol 攔截請求、回傳寫死的假回應，
/// 全程不連上真實的 api.telegram.org。
///
/// 用 .serialized：MockURLProtocol.requestHandler 是型別層級的共用狀態，
/// 如果測試被平行執行會互相踩到彼此設定的 handler，所以這個 suite 強制序列跑。
@Suite("URLSessionTelegramAPIClient", .serialized)
struct URLSessionTelegramAPIClientTests {
    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
        nonisolated(unsafe) static var capturedRequest: URLRequest?
        nonisolated(unsafe) static var capturedBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.capturedRequest = request
            // 平台行為不一樣：在 Darwin 上，URLSession 實際塞資料的地方是 httpBodyStream
            // （httpBody 在送出的請求物件上常常是 nil）；但在 Linux 的 swift-corelibs-foundation
            // 上剛好相反，httpBodyStream 是 nil、body 直接留在 httpBody 裡——這是這次為了
            // 驗證需求書「需能在 macOS 與 Linux 上執行」才用 Docker 實際跑過才發現的落差，
            // 之前只在 macOS 測過，兩邊都要顧到。
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                Self.capturedBody = data
            } else if let body = request.httpBody {
                Self.capturedBody = body
            }

            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: TelegramAPIError.apiError("no mock handler set"))
                return
            }
            do {
                let (statusCode, body) = try handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    func makeClient() -> URLSessionTelegramAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSessionTelegramAPIClient(token: "TEST_TOKEN", session: URLSession(configuration: config))
    }

    @Test("sendMessage without buttons: succeeds and the request body has no reply_markup key (inside)")
    func sendMessagePlainTextSucceeds() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":1,"chat":{"id":42},"text":"hi"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.sendMessage(chatID: 42, text: "hi", inlineKeyboard: nil)

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["chat_id"] as? Int64 == 42)
        #expect(json["text"] as? String == "hi")
        #expect(json["reply_markup"] == nil)
    }

    @Test("sendMessage with buttons: request body carries reply_markup.inline_keyboard (inside)")
    func sendMessageWithButtonsEncodesKeyboard() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":1,"chat":{"id":42},"text":"pick"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.sendMessage(
            chatID: 42,
            text: "pick",
            inlineKeyboard: [[TGInlineKeyboardButton(text: "A", callbackData: "a")]]
        )

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let markup = try #require(json["reply_markup"] as? [String: Any])
        let rows = try #require(markup["inline_keyboard"] as? [[[String: Any]]])
        #expect(rows[0][0]["text"] as? String == "A")
        #expect(rows[0][0]["callback_data"] as? String == "a")
    }

    @Test("sendMessage without parseMode: request body has no parse_mode key (boundary: default nil)")
    func sendMessageWithoutParseModeOmitsKey() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":1,"chat":{"id":42},"text":"hi"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.sendMessage(chatID: 42, text: "hi", inlineKeyboard: nil, parseMode: nil)

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["parse_mode"] == nil)
    }

    @Test("sendMessage with parseMode: HTML: request body carries parse_mode=HTML (inside)")
    func sendMessageWithParseModeEncodesIt() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":1,"chat":{"id":42},"text":"<b>hi</b>"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.sendMessage(chatID: 42, text: "<b>hi</b>", inlineKeyboard: nil, parseMode: .html)

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["parse_mode"] as? String == "HTML")
    }

    @Test("sendMessage with disableWebPagePreview: false (default): request body has no disable_web_page_preview key (boundary: matches Telegram's own default)")
    func sendMessageWithoutDisableWebPagePreviewOmitsKey() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":1,"chat":{"id":42},"text":"hi"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.sendMessage(chatID: 42, text: "hi", inlineKeyboard: nil, parseMode: nil, disableWebPagePreview: false)

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["disable_web_page_preview"] == nil)
    }

    @Test("sendMessage with disableWebPagePreview: true: request body carries disable_web_page_preview=true (inside)")
    func sendMessageWithDisableWebPagePreviewEncodesIt() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":1,"chat":{"id":42},"text":"hi https://example.com"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.sendMessage(chatID: 42, text: "hi https://example.com", inlineKeyboard: nil, parseMode: nil, disableWebPagePreview: true)

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["disable_web_page_preview"] as? Bool == true)
    }

    @Test("sendMessage where Telegram responds ok=false: throws .apiError, not a silent success (outside)")
    func sendMessageAPIErrorThrows() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":false,"description":"chat not found"}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        await #expect(throws: TelegramAPIError.self) {
            try await client.sendMessage(chatID: 42, text: "hi", inlineKeyboard: nil)
        }
    }

    @Test("sendMessage where the HTTP layer itself fails (500): throws .httpError (boundary: transport failure)")
    func sendMessageHTTPErrorThrows() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (500, "internal server error".data(using: .utf8)!)
        }
        let client = makeClient()

        await #expect(throws: TelegramAPIError.self) {
            try await client.sendMessage(chatID: 42, text: "hi", inlineKeyboard: nil)
        }
    }

    @Test("getUpdates: query carries offset/timeout, and the response is correctly mapped to [Update]")
    func getUpdatesParsesResponse() async throws {
        MockURLProtocol.handler = { (request: URLRequest) in
            let url = request.url!.absoluteString
            #expect(url.contains("offset=7"))
            #expect(url.contains("timeout=25"))
            let json = #"""
            {"ok":true,"result":[
              {"update_id":7,"message":{"message_id":1,"chat":{"id":42},"text":"/echo"}}
            ]}
            """#
            return (200, json.data(using: .utf8)!)
        }
        let client = makeClient()

        let updates = try await client.getUpdates(offset: 7, timeout: 25)

        #expect(updates.count == 1)
        #expect(updates[0].updateID == 7)
        #expect(updates[0].chatID == 42)
        #expect(updates[0].commandName == "echo")
    }

    @Test("getUpdates with no offset: the offset query parameter is omitted entirely (boundary: first poll)")
    func getUpdatesWithoutOffsetOmitsParam() async throws {
        MockURLProtocol.handler = { (request: URLRequest) in
            let url = request.url!.absoluteString
            #expect(!url.contains("offset="))
            return (200, #"{"ok":true,"result":[]}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        let updates = try await client.getUpdates(offset: nil, timeout: 25)
        #expect(updates.isEmpty)
    }

    @Test("getUpdates always explicitly requests callback_query in allowed_updates (inside)")
    func getUpdatesAlwaysRequestsCallbackQuery() async throws {
        // 實機測試發現的真實 bug：Telegram 會把「上一次呼叫帶的 allowed_updates」記在 bot
        // token 上、之後所有呼叫沿用同一個過濾設定，直到有人再明確帶一次不同的值為止。
        // 之前完全不帶這個參數，一旦有任何外部工具或舊測試曾經帶過不含 callback_query 的
        // allowed_updates，往後所有按鈕點擊都會被 Telegram 靜靜過濾掉、完全不會報錯，
        // 看起來就像「按了沒反應」。這裡守住：不管呼叫端有沒有想過這件事，我們都要主動
        // 明確要求 callback_query，不依賴伺服器端可能已經被汙染的殘留設定。
        MockURLProtocol.handler = { (request: URLRequest) in
            let url = request.url!.absoluteString
            #expect(url.contains("allowed_updates="))
            #expect(url.contains("callback_query") || url.contains("callback_query".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
            return (200, #"{"ok":true,"result":[]}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        _ = try await client.getUpdates(offset: nil, timeout: 25)
    }

    @Test("setMyCommands: request body maps (name, description) tuples to command/description keys")
    func setMyCommandsEncodesCommandList() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in (200, #"{"ok":true,"result":true}"#.data(using: .utf8)!) }
        let client = makeClient()

        try await client.setMyCommands([("cancel", "取消目前流程")])

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let commands = try #require(json["commands"] as? [[String: Any]])
        #expect(commands[0]["command"] as? String == "cancel")
        #expect(commands[0]["description"] as? String == "取消目前流程")
    }

    @Test("answerCallbackQuery: request body carries callback_query_id (inside)")
    func answerCallbackQuerySendsID() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in (200, #"{"ok":true,"result":true}"#.data(using: .utf8)!) }
        let client = makeClient()

        try await client.answerCallbackQuery(callbackQueryID: "cb-42")

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["callback_query_id"] as? String == "cb-42")
        #expect(json["text"] == nil)
    }

    @Test("answerCallbackQuery with a toast text: request body carries both fields (boundary: optional text)")
    func answerCallbackQueryWithTextSendsBoth() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in (200, #"{"ok":true,"result":true}"#.data(using: .utf8)!) }
        let client = makeClient()

        try await client.answerCallbackQuery(callbackQueryID: "cb-42", text: "已收到")

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["callback_query_id"] as? String == "cb-42")
        #expect(json["text"] as? String == "已收到")
    }

    @Test("editMessageReplyMarkup: request body carries chat_id/message_id but no reply_markup key (inside)")
    func editMessageReplyMarkupOmitsReplyMarkup() async throws {
        // 故意不帶 reply_markup 欄位：這是讓 Telegram 把整個 inline keyboard 拿掉的方式
        // （用來實現「舊按鈕點過就不能再點」，見 ConversationEngine.dispatch）。
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":999,"chat":{"id":42},"text":"pick"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.editMessageReplyMarkup(chatID: 42, messageID: 999)

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["chat_id"] as? Int64 == 42)
        #expect(json["message_id"] as? Int64 == 999)
        #expect(json["reply_markup"] == nil)
    }

    @Test("editMessageText: request body carries chat_id/message_id/text (inside)")
    func editMessageTextSendsFields() async throws {
        MockURLProtocol.handler = { (_: URLRequest) in
            (200, #"{"ok":true,"result":{"message_id":999,"chat":{"id":42},"text":"新文字"}}"#.data(using: .utf8)!)
        }
        let client = makeClient()

        try await client.editMessageText(chatID: 42, messageID: 999, text: "已選擇：男 ✅")

        let body = try #require(MockURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["chat_id"] as? Int64 == 42)
        #expect(json["message_id"] as? Int64 == 999)
        #expect(json["text"] as? String == "已選擇：男 ✅")
    }
}
