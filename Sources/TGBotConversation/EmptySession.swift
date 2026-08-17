/// 不需要 session 的 scene 可省略泛型參數，預設用這個空型別。見架構設計文件 6.1 節。
public struct EmptySession: Codable, Sendable {
    public init() {}
}
