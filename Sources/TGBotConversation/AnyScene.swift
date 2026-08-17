import Foundation
import TGBotTransport

/// 型別擦除包裝，內部持有一個具體的 Scene<State, Session>，對外只暴露
/// 「餵一個 Update 進去、跑對應的 handler」這個統一介面。
///
/// 存取層級更正：原本設計成 package（純內部管線型別），但它是 `Transition` 這個 public enum
/// 的 case（`.interrupt(with: AnyScene)`）關聯值型別，Swift 不允許 public enum 的 case
/// 帶有比自己更不公開的型別，因此被迫改為 public——這是實際編譯才會暴露的問題，文件審查
/// 沒抓到。即使公開，開發者一般也不會直接建構或操作它，仍然算是「內部實作示意」的角色。
public struct AnyScene: Sendable {
    private let _resume: @Sendable (Update, _ savedState: Data, _ savedSession: Data)
        async throws -> (transition: TransitionKind, newState: Data, newSession: Data)

    public init<State: ConversationState, Session: Codable & Sendable>(_ scene: Scene<State, Session>) {
        // TODO: 實作真正的解碼 → 呼叫對應 handler → 編碼回去，見架構設計文件 6.1.1 節
        self._resume = { _, savedState, savedSession in
            fatalError("AnyScene._resume 尚未實作")
        }
    }

    func resume(update: Update, savedState: Data, savedSession: Data) async throws
        -> (transition: TransitionKind, newState: Data, newSession: Data)
    {
        try await _resume(update, savedState, savedSession)
    }
}
