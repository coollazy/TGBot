/// 背景任務執行中回報進度用。用 actor（而非架構文件示意的 plain class）確保並發安全，
/// 呼叫端需要 `await progress.update(...)`——這是實作階段對示意程式碼的合理調整。
public actor JobProgress {
    public private(set) var lastMessage: String = ""

    public init() {}

    public func update(_ message: String) {
        lastMessage = message
    }
}
