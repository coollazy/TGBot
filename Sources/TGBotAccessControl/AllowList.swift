/// opt-in 白名單：兩個集合都是空的＝未設定＝公開模式，任何人都放行；
/// 只要設定了任一項就自動轉為私人模式。見架構設計文件第 5 節、需求書 US-4。
public struct AllowList: AccessPolicy, Sendable {
    public var userIDs: Set<Int64>
    public var chatIDs: Set<Int64>

    public init(userIDs: Set<Int64> = [], chatIDs: Set<Int64> = []) {
        self.userIDs = userIDs
        self.chatIDs = chatIDs
    }

    public func isAllowed(userID: Int64?, chatID: Int64) -> Bool {
        if userIDs.isEmpty && chatIDs.isEmpty { return true }
        if let userID, userIDs.contains(userID) { return true }
        return chatIDs.contains(chatID)
    }
}
