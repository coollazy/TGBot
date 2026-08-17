/// 完全不知道任何 scene 的 State／Session 具體型別，只認得 chatID／taskID。
/// 刻意標為 public（可測試性例外，見架構設計文件 6.6／13 節）：開發者在自己的測試裡
/// 可以注入符合這個 protocol 的假排程器，不用真的跑異步工作。
public protocol BackgroundTaskScheduling: Sendable {
    func start(
        chatID: Int64,
        taskID: String,
        work: @escaping @Sendable (JobProgress) async throws -> Void,
        onComplete: @escaping @Sendable (JobResult) async throws -> Void
    ) async
    func status(chatID: Int64, taskID: String) async -> JobStatus?
}
