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

/// `AnyScene._resume`／`AnyScene._enter` 都要把 handler 回傳的 `Transition<State>`
/// 轉成引擎看得懂的擦除後 tuple——兩邊邏輯完全一樣（差別只在「誰呼叫、用什麼 Context」，
/// 不在「怎麼解讀 Transition」），抽成一個共用函式，不要複製兩份幾乎一樣的 switch。
package func processSceneTransition<State: ConversationState, Session: Codable & Sendable>(
    _ transition: Transition<State>,
    scene: Scene<State, Session>,
    state: State,
    ctx: Context<State, Session>,
    stateHistory: [Data],
    encoder: JSONEncoder
) throws -> (
    transition: TransitionKind,
    newState: Data?,
    newSession: Data,
    newHistory: [Data],
    suspended: SuspendedScene?,
    interruptingScene: AnyScene?,
    resultData: Data?
) {
    switch transition {
    case .transition(to: let newState):
        // 往下走之前，把「現在正要離開的這個 state」推進歷史棧——這是 .rollback
        // 要退回去的目標。US-2：退回上一步重試，不是回到最開始。
        let newHistory = stateHistory + [try encoder.encode(state)]
        return (.moved, try encoder.encode(newState), try encoder.encode(ctx.session), newHistory, nil, nil, nil)
    case .stay:
        return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), stateHistory, nil, nil, nil)
    case .end:
        return (.ended, nil, try encoder.encode(ctx.session), [], nil, nil, nil)
    case .endWithResult(let resultData):
        // 跟 .end 完全一樣，只是多把編碼好的結果原樣帶出去——ConversationEngine
        // 只有在被彈出的 SuspendedScene 真的有註冊 returnHandler 時才會用到它，
        // 否則（例如這個 scene 根本不是被中斷帶進來的）就跟 plain .end 沒有差別。
        return (.ended, nil, try encoder.encode(ctx.session), [], nil, nil, resultData)
    case .rollback:
        guard let previousStateData = stateHistory.last else {
            // 沒有更早的步驟可以退——不當成錯誤，單純停在原地沒有效果
            return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), stateHistory, nil, nil, nil)
        }
        return (.rolledBack, previousStateData, try encoder.encode(ctx.session), Array(stateHistory.dropLast()), nil, nil, nil)
    case .interrupt(let newScene):
        // 把「現在這個 scene，暫停當下的 state/session」包成 SuspendedScene 推上
        // sceneStack，讓 newScene 開始跑；newScene .end 的時候，ConversationEngine
        // 會把這個 SuspendedScene 彈出來、原地恢復。用 AnyScene(scene) 重新包一次
        // 目前這個 scene——這裡就是原本那個 AnyScene 的建構過程本身，還沒有
        // 「自己完整建構好的 self」可以直接參照，重新包一份等價的是最直接的做法。
        let suspended = SuspendedScene(
            scene: AnyScene(scene),
            savedState: try encoder.encode(state),
            savedSession: try encoder.encode(ctx.session),
            savedStateHistory: stateHistory
        )
        return (.interrupted, nil, Data(), [], suspended, newScene, nil)
    case .interruptWithReturn(let newScene, let returnHandler):
        // 跟 .interrupt 完全一樣，只是多把 returnHandler 一起存進 SuspendedScene，
        // 讓 ConversationEngine 在子流程用 .end(with:) 帶結果彈回來時能呼叫它。
        let suspended = SuspendedScene(
            scene: AnyScene(scene),
            savedState: try encoder.encode(state),
            savedSession: try encoder.encode(ctx.session),
            savedStateHistory: stateHistory,
            returnHandler: returnHandler
        )
        return (.interrupted, nil, Data(), [], suspended, newScene, nil)
    }
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
    // `.interrupt(with: AnyScene(childScene, initialSession: ...))` 帶進來的初始
    // session（已編碼）。nil 代表沒有給，子流程照舊從 scene.initialSession 開始
    // （既有行為，完全不受影響）。見 ConversationEngine 的 `.interrupted` 分支。
    let initialSessionOverride: Data?

    private let _resume: @Sendable (Update, _ savedState: Data?, _ savedSession: Data, _ stateHistory: [Data], SceneDependencies)
        async throws -> (
            transition: TransitionKind,
            newState: Data?,
            newSession: Data,
            newHistory: [Data],
            suspended: SuspendedScene?,
            interruptingScene: AnyScene?,
            resultData: Data?
        )
    // `stateData` 是 nil 代表「用 scene.initial」（跟 _resume 的 savedState 同一套慣例），
    // 給定值代表「轉移到的目標 state」。回傳 nil 代表這個 state 沒有註冊 onEnter，
    // 呼叫端（ConversationEngine）才知道要 fall back 成原本沒有這個功能之前的行為。
    private let _enter: @Sendable (_ stateData: Data?, _ sessionData: Data, _ stateHistory: [Data], _ chatID: Int64, _ userID: Int64?, SceneDependencies)
        async throws -> (
            transition: TransitionKind,
            newState: Data?,
            newSession: Data,
            newHistory: [Data],
            suspended: SuspendedScene?,
            interruptingScene: AnyScene?,
            resultData: Data?
        )?
    private let _notifyResumed: @Sendable (Int64, Int64?, Data, Data, SceneDependencies) async throws -> Void

    public init<State: ConversationState, Session: Codable & Sendable>(
        _ scene: Scene<State, Session>,
        initialSession: Session? = nil
    ) {
        self.name = scene.name
        if let initialSession {
            self.initialSessionOverride = try? canonicalJSONEncoder().encode(initialSession)
        } else {
            self.initialSessionOverride = nil
        }

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
            let encoder = canonicalJSONEncoder()

            let state: State
            if let savedStateData, let decoded = try? decoder.decode(State.self, from: savedStateData) {
                state = decoded
            } else {
                state = scene.initial
            }
            let session: Session = (try? decoder.decode(Session.self, from: savedSessionData)) ?? scene.initialSession

            guard let handler = scene.handlers.handler(for: state) else {
                // 這個 state 沒有註冊 handler：視為停留原地，不改變任何東西
                return (.stayed, try encoder.encode(state), try encoder.encode(session), stateHistory, nil, nil, nil)
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
            return try processSceneTransition(transition, scene: scene, state: state, ctx: ctx, stateHistory: stateHistory, encoder: encoder)
        }

        self._enter = { stateData, sessionData, stateHistory, chatID, userID, dependencies in
            let decoder = JSONDecoder()
            let encoder = canonicalJSONEncoder()

            let state: State
            if let stateData, let decoded = try? decoder.decode(State.self, from: stateData) {
                state = decoded
            } else {
                state = scene.initial
            }

            guard let handler = scene.enterHandlers.handler(for: state) else {
                return nil // 沒註冊 onEnter：呼叫端 fall back 成原本行為
            }

            let session: Session = (try? decoder.decode(Session.self, from: sessionData)) ?? scene.initialSession
            let ctx = Context<State, Session>(
                chatID: chatID,
                userID: userID,
                text: nil, // 進場自動觸發，不是在處理使用者傳來的東西
                callbackData: nil,
                session: session,
                sceneName: scene.name,
                apiClient: dependencies.apiClient,
                scheduler: dependencies.scheduler,
                engine: dependencies.engine,
                logger: dependencies.logger
            )

            let transition = try await handler(ctx)
            return try processSceneTransition(transition, scene: scene, state: state, ctx: ctx, stateHistory: stateHistory, encoder: encoder)
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
        interruptingScene: AnyScene?,
        resultData: Data?
    ) {
        try await _resume(update, savedState, savedSession, stateHistory, dependencies)
    }

    /// 轉移進入 `stateData`（nil 代表 scene.initial）當下呼叫，讓已註冊的 onEnter
    /// 有機會不等使用者輸入就自動處理。回傳 nil 代表這個 state 沒有註冊 onEnter，
    /// 呼叫端要 fall back 成原本（沒有這個功能之前）的行為。
    func enter(
        stateData: Data?,
        sessionData: Data,
        stateHistory: [Data],
        chatID: Int64,
        userID: Int64?,
        dependencies: SceneDependencies
    ) async throws -> (
        transition: TransitionKind,
        newState: Data?,
        newSession: Data,
        newHistory: [Data],
        suspended: SuspendedScene?,
        interruptingScene: AnyScene?,
        resultData: Data?
    )? {
        try await _enter(stateData, sessionData, stateHistory, chatID, userID, dependencies)
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
