import Foundation
import Logging
import TGBotAccessControl

extension TGBot {
    /// 見架構設計文件 6.5／9／13 節：Bot Token 以字串參數為主，另提供讀環境變數的
    /// convenience initializer 當語法糖；白名單 opt-in；log level 預設 .error。
    public struct Configuration: Sendable {
        public var token: String
        public var allowList: AllowList
        public var logLevel: Logger.Level
        public var unauthorizedMessage: @Sendable (Int64?, Int64) -> String

        public init(
            token: String,
            allowList: AllowList = AllowList(),
            logLevel: Logger.Level = .error,
            unauthorizedMessage: @escaping @Sendable (Int64?, Int64) -> String = Configuration.defaultUnauthorizedMessage
        ) {
            self.token = token
            self.allowList = allowList
            self.logLevel = logLevel
            self.unauthorizedMessage = unauthorizedMessage
        }

        /// B：讀環境變數的 convenience initializer，見架構設計文件第 9 節範例。
        public init(
            tokenFromEnv envKey: String,
            allowList: AllowList = AllowList(),
            logLevel: Logger.Level = .error,
            unauthorizedMessage: @escaping @Sendable (Int64?, Int64) -> String = Configuration.defaultUnauthorizedMessage
        ) {
            let token = ProcessInfo.processInfo.environment[envKey] ?? ""
            self.init(token: token, allowList: allowList, logLevel: logLevel, unauthorizedMessage: unauthorizedMessage)
        }

        public static func defaultUnauthorizedMessage(userID: Int64?, chatID: Int64) -> String {
            """
            This is a private bot.
            You are not authorized to use it.

            user_id: \(userID.map(String.init) ?? "unknown")
            chat_id: \(chatID)
            """
        }
    }
}
