/// 白名單過濾邏輯，在 Update 進入 Conversation Engine 前先行攔截。見架構設計文件第 5 節。
public protocol AccessPolicy: Sendable {
    func isAllowed(userID: Int64?, chatID: Int64) -> Bool
}
