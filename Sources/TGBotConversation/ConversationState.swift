/// 同時要求 Hashable（供具體 Scene 內部用 dictionary 分派 handler）
/// 與 Codable（供 ChatConversationRecord 的型別擦除儲存）。見架構設計文件 6.1／13 節。
public protocol ConversationState: Codable, Hashable, Sendable {}
