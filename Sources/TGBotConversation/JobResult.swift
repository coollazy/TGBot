/// 背景任務結束時的結果。定義在 TGBotConversation（而非 TGBotBackgroundTask）：
/// Context.startBackgroundJob 的公開簽名需要用到這個型別，若定義在 TGBotBackgroundTask，
/// 會跟「BackgroundTaskManager 需要依賴 TGBotConversation 才能安全回呼」形成循環依賴，
/// 因此把契約型別（JobResult／JobStatus／JobProgress／BackgroundTaskScheduling）都留在這裡，
/// TGBotBackgroundTask 只放 v1 的具體實作（BackgroundTaskManager）。見架構設計文件第 7 節。
// @unchecked Sendable：關聯值 `any Error` 本身不保證 Sendable（Swift 6 嚴格並發檢查下，
// 任意 Error 型別可能持有非 Sendable 資料），這裡先接受這個已知風險放行，
// 之後若需要完全的並發安全，可考慮改用限定 Sendable 的自訂錯誤型別。
public enum JobResult: @unchecked Sendable {
    case success
    case failure(Error)
}
