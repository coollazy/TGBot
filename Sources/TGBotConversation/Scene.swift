import Foundation

/// 對話狀態圖裡的一個 scene。刻意用 class（而非 struct）：開發者慣用
/// `let registration = Scene(...)` 接著連續呼叫多次 `.on(...)` 註冊 handler，
/// struct 的話 `.on(...)` 要嘛得標 mutating、要嘛得把 registration 宣告成 var，
/// 兩者都不符合這種「宣告後就當常數使用」的寫法。見架構設計文件 6.1 節。
public final class Scene<State: ConversationState, Session: Codable & Sendable>: Sendable {
    public let name: String
    public let initial: State
    public let initialSession: Session

    // 內部儲存每個 state 對應的處理函式；class 讓 on(...) 不需要 mutating 即可寫入
    package let handlers: HandlerStorage<State, Session>

    // 每個 state 對應「從中斷它的子流程恢復時」要做的事（通常是回一句話重新交代現在
    // 在等什麼）。刻意獨立於 handlers 之外：resume 這件事不是「使用者傳了什麼進來」，
    // 沒有 Update 可以處理，語意上跟 on(...) 是兩種不同的註冊。
    package let resumeHandlers: ResumeHandlerStorage<State, Session>

    public init(name: String, initial: State, initialSession: Session) {
        self.name = name
        self.initial = initial
        self.initialSession = initialSession
        self.handlers = HandlerStorage()
        self.resumeHandlers = ResumeHandlerStorage()
    }

    /// 每個 state 對應一個處理函式，ctx.session 型別即為開發者指定的 Session
    public func on(
        _ state: State,
        handler: @escaping @Sendable (Context<State, Session>) async throws -> Transition<State>
    ) {
        handlers.set(state, handler)
    }

    /// 選配：這個 state 被 Transition.interrupt 中斷、子流程結束後恢復時，要跟使用者說什麼。
    /// 見架構設計文件 US-1——中斷/恢復本身框架會自動處理，但「恢復時要講什麼話」只有
    /// 開發者自己知道（使用者不知道什麼是「scene」、什麼是「子流程」，框架硬塞一句通用訊息
    /// 對使用者來說毫無意義），所以設計成選配 hook，不註冊就維持原本的靜默行為
    /// （下一句使用者輸入直接照原本的 on(...) handler 處理，不會多這一句話）。
    public func onResume(
        _ state: State,
        handler: @escaping @Sendable (Context<State, Session>) async throws -> Void
    ) {
        resumeHandlers.set(state, handler)
    }
}

/// Scene 的 handler dictionary 存放在獨立的鎖保護容器裡，讓 Scene 本身可以安全地標為 Sendable，
/// 同時 `on(...)` 維持同步呼叫（開發者慣用 `scene.on(.x) { ctx in ... }`，不想被迫 `await`）。
/// 原本想用 actor 包一層，但 actor 的方法天生是 async，會強迫 `on(...)` 也變成 async，
/// 破壞這個註冊 API 想要的同步寫法——這是實際編譯後才發現要調整的地方，改用鎖代替。
package final class HandlerStorage<State: ConversationState, Session: Codable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [State: @Sendable (Context<State, Session>) async throws -> Transition<State>] = [:]

    package init() {}

    package func set(
        _ state: State,
        _ handler: @escaping @Sendable (Context<State, Session>) async throws -> Transition<State>
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[state] = handler
    }

    package func handler(for state: State) -> (@Sendable (Context<State, Session>) async throws -> Transition<State>)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[state]
    }
}

/// 跟 HandlerStorage 同一套鎖保護容器設計，差別只在 handler 的型別（沒有 Transition
/// 回傳值——resume 通知本身不該導致狀態再往下走，見 Scene.onResume）。
package final class ResumeHandlerStorage<State: ConversationState, Session: Codable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [State: @Sendable (Context<State, Session>) async throws -> Void] = [:]

    package init() {}

    package func set(
        _ state: State,
        _ handler: @escaping @Sendable (Context<State, Session>) async throws -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[state] = handler
    }

    package func handler(for state: State) -> (@Sendable (Context<State, Session>) async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[state]
    }
}

extension Scene where Session == EmptySession {
    /// 不需要 session 的 scene 可省略 initialSession，用條件 extension 限定只在
    /// Session == EmptySession 時提供這個更簡短的 init。
    public convenience init(name: String, initial: State) {
        self.init(name: name, initial: initial, initialSession: EmptySession())
    }
}
