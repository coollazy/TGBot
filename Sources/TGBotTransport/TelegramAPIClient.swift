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

    public init(token: String, session: URLSession = .shared, logger: Logger = Logger(label: "TGBotTransport")) {
        self.token = token
        self.session = session
        self.logger = logger
    }

    public func sendMessage(chatID: Int64, text: String) async throws {
        // TODO: 實作 https://api.telegram.org/bot<token>/sendMessage 呼叫（JSON body、錯誤解析）
        fatalError("URLSessionTelegramAPIClient.sendMessage 尚未實作")
    }

    public func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] {
        // TODO: 實作 https://api.telegram.org/bot<token>/getUpdates 長輪詢呼叫
        fatalError("URLSessionTelegramAPIClient.getUpdates 尚未實作")
    }

    public func setMyCommands(_ commands: [(name: String, description: String)]) async throws {
        // TODO: 實作 https://api.telegram.org/bot<token>/setMyCommands 呼叫（見架構設計文件 8.1 節）
        fatalError("URLSessionTelegramAPIClient.setMyCommands 尚未實作")
    }
}
