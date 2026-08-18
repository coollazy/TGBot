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
        async throws -> (transition: TransitionKind, newState: Data?, newSession: Data, newHistory: [Data])

    public init<State: ConversationState, Session: Codable & Sendable>(_ scene: Scene<State, Session>) {
        self.name = scene.name
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
                return (.stayed, try encoder.encode(state), try encoder.encode(session), stateHistory)
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
                return (.moved, try encoder.encode(newState), try encoder.encode(ctx.session), newHistory)
            case .stay:
                return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), stateHistory)
            case .end:
                return (.ended, nil, try encoder.encode(ctx.session), [])
            case .rollback:
                guard let previousStateData = stateHistory.last else {
                    // 沒有更早的步驟可以退——不當成錯誤，單純停在原地沒有效果
                    return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), stateHistory)
                }
                return (.rolledBack, previousStateData, try encoder.encode(ctx.session), Array(stateHistory.dropLast()))
            case .interrupt:
                // TODO: scene 棧的暫停/恢復，下一階段實作
                fatalError("AnyScene interrupt 尚未實作")
            }
        }
    }

    func resume(
        update: Update,
        savedState: Data?,
        savedSession: Data,
        stateHistory: [Data],
        dependencies: SceneDependencies
    ) async throws -> (transition: TransitionKind, newState: Data?, newSession: Data, newHistory: [Data]) {
        try await _resume(update, savedState, savedSession, stateHistory, dependencies)
    }
}
