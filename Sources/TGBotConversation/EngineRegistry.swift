import Foundation

/// scene／指令的註冊表。刻意用鎖保護的 class（而非 actor）：TGBot.register(...)／
/// onCommand(...) 需要維持同步呼叫（開發者慣用寫法不想被迫 await），若註冊表本身是 actor，
/// 寫入會強制變成 async，而且 fire-and-forget 的 `Task { await ... }` 沒辦法保證
/// 在 `bot.run()` 開始輪詢前真的寫入完成，會有 race condition——這是實際串起 TGBot
/// 主流程才發現要調整的地方，跟 Scene.on(...) 遇到的問題同一類。
/// 存取層級更正：本來只想給 TGBot／ConversationEngine 內部用，但 `ConversationEngine`
/// 的 public init 需要接收它（TGBot 在別的 target，要建構 ConversationEngine 就得跨 module
/// 傳進來），Swift 不允許 public 簽名帶著比自己更不公開的型別，所以被迫公開——
/// 跟 AnyScene／ChatConversationRecord 是同一類「實際編譯才會暴露」的存取層級問題。
public final class EngineRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scenesByName: [String: AnyScene] = [:]
    private var sceneTriggers: [String: AnyScene] = [:]
    private var commandHandlers: [String: @Sendable (GlobalContext) async throws -> Void] = [:]
    private var unhandledHandler: (@Sendable (GlobalContext) async throws -> Void)?
    private var errorHandler: (@Sendable (GlobalContext, Error) async throws -> Void)?

    public init() {}

    public func registerScene<State: ConversationState, Session: Codable & Sendable>(
        _ scene: Scene<State, Session>,
        commandTrigger: String
    ) {
        let erased = AnyScene(scene)
        lock.lock()
        defer { lock.unlock() }
        scenesByName[scene.name] = erased
        sceneTriggers[commandTrigger] = erased
    }

    public func registerCommand(_ name: String, handler: @escaping @Sendable (GlobalContext) async throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        commandHandlers[name] = handler
    }

    public func setUnhandledHandler(_ handler: @escaping @Sendable (GlobalContext) async throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        unhandledHandler = handler
    }

    public func setErrorHandler(_ handler: @escaping @Sendable (GlobalContext, Error) async throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        errorHandler = handler
    }

    func scene(named name: String) -> AnyScene? {
        lock.lock()
        defer { lock.unlock() }
        return scenesByName[name]
    }

    func scene(forTrigger command: String) -> AnyScene? {
        lock.lock()
        defer { lock.unlock() }
        return sceneTriggers[command]
    }

    func commandHandler(for name: String) -> (@Sendable (GlobalContext) async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return commandHandlers[name]
    }

    func unhandledHandlerIfAny() -> (@Sendable (GlobalContext) async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return unhandledHandler
    }

    func errorHandlerIfAny() -> (@Sendable (GlobalContext, Error) async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return errorHandler
    }
}
