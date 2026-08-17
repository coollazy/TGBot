import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging

/// 對外呼叫 Telegram Bot API 的能力。一次性呼叫（如 sendMessage）依 4.1 節規則不重試，
/// 失敗直接 throw，交由呼叫端（最終是 6.5 節的錯誤處理路徑）決定要不要通知使用者或自己重送。
public protocol TelegramAPIClient: Sendable {
    func sendMessage(chatID: Int64, text: String) async throws
    func getUpdates(offset: Int?, timeout: Int) async throws -> [Update]
    func setMyCommands(_ commands: [(name: String, description: String)]) async throws
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

    public func sendMessage(chatID: Int64, text: String) async throws {
        struct Body: Encodable {
            let chatID: Int64
            let text: String
            enum CodingKeys: String, CodingKey {
                case chatID = "chat_id"
                case text
            }
        }
        _ = try await post(
            path: "sendMessage",
            body: Body(chatID: chatID, text: text),
            responseType: TGMessage.self
        )
    }

    public func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] {
        var components = URLComponents(string: "\(baseURL)/getUpdates")!
        var queryItems = [URLQueryItem(name: "timeout", value: String(timeout))]
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
