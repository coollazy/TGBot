import Foundation

/// 可注入的時間來源，讓退避重試等邏輯在測試時能被瞬間跑完。見架構設計文件 4.1／6.6 節。
///
/// 命名為 TimeProvider 而非 Clock：Swift 標準庫自己有一個 `Clock` protocol
/// （Swift 5.7+，`ContinuousClock`/`SuspendingClock` 那套），撞名會讓編譯器解析錯型別、
/// 報出難以理解的錯誤（這是文件審查沒抓到、實際編譯才會現形的問題）。
public protocol TimeProvider: Sendable {
    func now() -> Date
    func sleep(for duration: TimeInterval) async throws
}

public struct SystemTimeProvider: TimeProvider {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
