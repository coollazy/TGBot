import Logging
import TGBotTransport

/// 不綁定特定 scene 的 State/Session、跨所有 handler 通用的基底能力，全域指令
/// （例如 /cancel）拿到的就是這個型別。見架構設計文件 6.1／8.1 節。
public class GlobalContext: @unchecked Sendable {
    public let chatID: Int64
    public let userID: Int64?
    public let text: String?
    public let callbackData: String?

    let apiClient: TelegramAPIClient
    let engine: ConversationEngineHandle
    let logger: Logger

    init(
        chatID: Int64,
        userID: Int64?,
        text: String?,
        callbackData: String?,
        apiClient: TelegramAPIClient,
        engine: ConversationEngineHandle,
        logger: Logger
    ) {
        self.chatID = chatID
        self.userID = userID
        self.text = text
        self.callbackData = callbackData
        self.apiClient = apiClient
        self.engine = engine
        self.logger = logger
    }

    public func reply(_ text: String) async throws {
        try await apiClient.sendMessage(chatID: chatID, text: text)
    }

    public func replyWithMenu(_ text: String, buttons: [[InlineButton]]) async throws {
        // TODO: 實作帶 inline keyboard 的 sendMessage，見架構設計文件第 8 節
        try await apiClient.sendMessage(chatID: chatID, text: text)
    }

    /// US-5：清空目前 chat 的 scene/state/session/歷史棧/scene 棧，回到 idle。
    /// 不影響 pendingCompletions（背景任務通知），見架構設計文件 6.2／7.1 節。
    public func resetConversation() async {
        await engine.resetConversation(chatID: chatID)
    }
}
