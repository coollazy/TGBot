/// 抽象化「怎麼取得 Update」，讓 Polling／Webhook 可以互換。見架構設計文件第 4 節。
public protocol UpdateSource: Sendable {
    func start(onUpdate: @escaping @Sendable (Update) async -> Void) async throws
    func stop() async
}
