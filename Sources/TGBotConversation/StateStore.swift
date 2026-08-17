/// 刻意將持久化行為收斂在單一 protocol 背後，即使 v1 只有記憶體實作，未來若需求改變
/// （例如要支援重啟不遺失），只需新增一個實作，不影響上層邏輯。刻意標為 public
/// （可測試性例外，見架構設計文件 6.3／6.6／13 節）。
public protocol StateStore: Sendable {
    func load(chatID: Int64) async -> ChatConversationRecord
    func save(chatID: Int64, _ record: ChatConversationRecord) async
}
