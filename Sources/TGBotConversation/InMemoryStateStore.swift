/// v1：唯一實作，符合需求書「不需跨重啟保存」。見架構設計文件 6.3 節。
public actor InMemoryStateStore: StateStore {
    private var records: [Int64: ChatConversationRecord] = [:]

    public init() {}

    public func load(chatID: Int64) async -> ChatConversationRecord {
        records[chatID] ?? ChatConversationRecord()
    }

    public func save(chatID: Int64, _ record: ChatConversationRecord) async {
        records[chatID] = record
    }
}
