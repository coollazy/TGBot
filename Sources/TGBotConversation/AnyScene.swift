import Foundation
import TGBotTransport
import Logging

/// AnyScene 內部呼叫 handler 時需要的外部依賴，跟型別擦除包在一起才能建構出真正的 Context。
struct SceneDependencies: Sendable {
    let apiClient: TelegramAPIClient
    let scheduler: BackgroundTaskScheduling
    let engine: ConversationEngineHandle
    let logger: Logger
}

/// 型別擦除包裝，內部持有一個具體的 Scene<State, Session>，對外只暴露
/// 「餵一個 Update 進去、跑對應的 handler」這個統一介面。
///
/// 存取層級更正：原本設計成 package（純內部管線型別），但它是 `Transition` 這個 public enum
/// 的 case（`.interrupt(with: AnyScene)`）關聯值型別，Swift 不允許 public enum 的 case
/// 帶有比自己更不公開的型別，因此被迫改為 public——這是實際編譯才會暴露的問題，文件審查
/// 沒抓到。即使公開，開發者一般也不會直接建構或操作它，仍然算是「內部實作示意」的角色。
public struct AnyScene: Sendable {
    let name: String
    private let _resume: @Sendable (Update, _ savedState: Data?, _ savedSession: Data, _ stateHistory: [Data], SceneDependencies)
        async throws -> (
            transition: TransitionKind,
            newState: Data?,
            newSession: Data,
            newHistory: [Data],
            suspended: SuspendedScene?,
            interruptingScene: AnyScene?
        )
    private let _notifyResumed: @Sendable (Int64, Int64?, Data, Data, SceneDependencies) async throws -> Void

    public init<State: ConversationState, Session: Codable & Sendable>(_ scene: Scene<State, Session>) {
        self.name = scene.name
        self._notifyResumed = { chatID, userID, savedStateData, savedSessionData, dependencies in
            guard let state = try? JSONDecoder().decode(State.self, from: savedStateData),
                  let handler = scene.resumeHandlers.handler(for: state) else {
                return // 沒註冊 onResume：維持原本的靜默行為，不是漏做事
            }
            let session: Session = (try? JSONDecoder().decode(Session.self, from: savedSessionData)) ?? scene.initialSession
            let ctx = Context<State, Session>(
                chatID: chatID,
                userID: userID,
                text: nil, // 這不是在處理使用者傳來的東西，沒有對應的文字/按鈕可以帶
                callbackData: nil,
                session: session,
                sceneName: scene.name,
                apiClient: dependencies.apiClient,
                scheduler: dependencies.scheduler,
                engine: dependencies.engine,
                logger: dependencies.logger
            )
            try await handler(ctx)
        }
        self._resume = { update, savedStateData, savedSessionData, stateHistory, dependencies in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()

            let state: State
            if let savedStateData, let decoded = try? decoder.decode(State.self, from: savedStateData) {
                state = decoded
            } else {
                state = scene.initial
            }
            let session: Session = (try? decoder.decode(Session.self, from: savedSessionData)) ?? scene.initialSession

            guard let handler = scene.handlers.handler(for: state) else {
                // 這個 state 沒有註冊 handler：視為停留原地，不改變任何東西
                return (.stayed, try encoder.encode(state), try encoder.encode(session), stateHistory, nil, nil)
            }

            let ctx = Context<State, Session>(
                chatID: update.chatID,
                userID: update.userID,
                text: update.text,
                callbackData: update.callbackData,
                messageID: update.messageID,
                session: session,
                sceneName: scene.name,
                apiClient: dependencies.apiClient,
                scheduler: dependencies.scheduler,
                engine: dependencies.engine,
                logger: dependencies.logger
            )

            let transition = try await handler(ctx)

            switch transition {
            case .transition(to: let newState):
                // 往下走之前，把「現在正要離開的這個 state」推進歷史棧——這是 .rollback
                // 要退回去的目標。US-2：退回上一步重試，不是回到最開始。
                let newHistory = stateHistory + [try encoder.encode(state)]
                return (.moved, try encoder.encode(newState), try encoder.encode(ctx.session), newHistory, nil, nil)
            case .stay:
                return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), stateHistory, nil, nil)
            case .end:
                return (.ended, nil, try encoder.encode(ctx.session), [], nil, nil)
            case .rollback:
                guard let previousStateData = stateHistory.last else {
                    // 沒有更早的步驟可以退——不當成錯誤，單純停在原地沒有效果
                    return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), stateHistory, nil, nil)
                }
                return (.rolledBack, previousStateData, try encoder.encode(ctx.session), Array(stateHistory.dropLast()), nil, nil)
            case .interrupt(let newScene):
                // 把「現在這個 scene，暫停當下的 state/session」包成 SuspendedScene 推上
                // sceneStack，讓 newScene 開始跑；newScene .end 的時候，ConversationEngine
                // 會把這個 SuspendedScene 彈出來、原地恢復。用 AnyScene(scene) 重新包一次
                // 目前這個 scene——這裡就是原本那個 AnyScene 的建構過程本身，還沒有
                // 「自己完整建構好的 self」可以直接參照，重新包一份等價的是最直接的做法。
                //
                // 已知限制（最小版本，範圍已跟使用者確認過）：暫停的 stateHistory 不會被
                // 保留，恢復之後這個 scene 的 rollback 歷史是空的；子流程執行完的結果也
                // 不會自動傳回給被中斷的流程，開發者要自己想辦法（例如透過外部共享狀態），
                // 這兩點都留待有實際需求再做。
                let suspended = SuspendedScene(
                    scene: AnyScene(scene),
                    savedState: try encoder.encode(state),
                    savedSession: try encoder.encode(ctx.session)
                )
                return (.interrupted, nil, Data(), [], suspended, newScene)
            }
        }
    }

    func resume(
        update: Update,
        savedState: Data?,
        savedSession: Data,
        stateHistory: [Data],
        dependencies: SceneDependencies
    ) async throws -> (
        transition: TransitionKind,
        newState: Data?,
        newSession: Data,
        newHistory: [Data],
        suspended: SuspendedScene?,
        interruptingScene: AnyScene?
    ) {
        try await _resume(update, savedState, savedSession, stateHistory, dependencies)
    }

    /// 從中斷它的子流程恢復時呼叫。這個 scene 對 savedState 那個 state 有沒有註冊
    /// onResume(_:handler:) 完全是選配的——沒註冊就什麼事都不做，維持原本（修這個功能
    /// 之前就有的）靜默行為，不會因為加了這個功能就強迫所有既有的 scene 多一句話。
    func notifyResumed(
        chatID: Int64,
        userID: Int64?,
        savedState: Data,
        savedSession: Data,
        dependencies: SceneDependencies
    ) async throws {
        try await _notifyResumed(chatID, userID, savedState, savedSession, dependencies)
    }
}
