import Foundation

/// 每個 chat 一份，記錄目前所在的 scene／state、session 資料、狀態歷史棧（供 rollback）、
/// scene 棧（供 interrupt／resume）。
///
/// 存取層級更正：原設計是 package（純內部管線型別），但 `StateStore`（6.3／6.6 節，public，
/// 可測試性例外）的 `load`／`save` 簽名直接傳遞這個型別，Swift 不允許 public protocol
/// 方法的參數／回傳值型別比方法本身更不公開，因此被迫改為 public——這是實際編譯才會
/// 暴露的問題，文件審查沒抓到。開發者要自己實作 StateStore（例如測試用假實作）時，
/// 才會直接接觸到這個型別，一般開發流程仍不會用到。
///
/// `pendingCompletions`（背景任務完成回呼）刻意不放在這個型別裡，而是由 ConversationEngine
/// 另外用一份純記憶體的字典保管：閉包無法 Codable 化，若跟著這個 struct 一起走
/// StateStore 的 load/save 路徑，未來要支援可持久化 StateStore 實作時會直接卡死；
/// 讓它完全獨立於「可能被持久化」的欄位之外，也讓「.end／resetConversation() 不影響
/// 待通知的背景任務」這件事（US-5／US-6）更直接成立，見 ConversationEngine.swift。
public struct ChatConversationRecord: Sendable {
    public var activeScene: String?
    public var currentStateData: Data?
    public var sessionData: Data
    public var stateHistory: [Data]
    public var sceneStack: [SuspendedScene]

    public init(
        activeScene: String? = nil,
        currentStateData: Data? = nil,
        sessionData: Data = Data(),
        stateHistory: [Data] = [],
        sceneStack: [SuspendedScene] = []
    ) {
        self.activeScene = activeScene
        self.currentStateData = currentStateData
        self.sessionData = sessionData
        self.stateHistory = stateHistory
        self.sceneStack = sceneStack
    }

    /// US-5：清空對話流程本身的欄位。
    public mutating func reset() {
        activeScene = nil
        currentStateData = nil
        sessionData = Data()
        stateHistory = []
        sceneStack = []
    }
}
