import Foundation

/// 把 `.interrupt(with:onReturn:)` 的 onReturn 閉包型別擦除掉，讓它能存進只對 `State`
/// 泛型的 `Transition<State>` 裡——跟 `AnyScene` 擦除 `Scene<State, Session>` 是同一個套路。
///
/// 子流程用 `.end(with:)` 帶結果結束、彈回父流程時，`ConversationEngine.dispatch` 會呼叫
/// `invoke(...)`：把結果／父流程當下的 state／session 解碼回具體型別、組出一個
/// `Context<State, Session>`（`text`/`callbackData` 是 nil——這不是在處理使用者送來的訊息，
/// 是子流程結束觸發的自動呼叫），呼叫開發者的 onReturn，再把它回傳的 `Transition<State>`
/// 轉成跟 `AnyScene.resume(...)` 同樣格式的 tuple，讓 dispatch 能直接把這個結果接回主迴圈
/// 繼續處理（可能又是 `.transition`／`.stay`／`.rollback`／`.end`，甚至繼續往更上層的
/// 被中斷流程傳）。
///
/// 已知限制：onReturn 回傳 `.interrupt`／`.interruptWithReturn` 不支援——這是「自動觸發的
/// 路徑不能連續觸發新的 interrupt」這條既有限制的同一種情況（跟背景任務完成不能觸發
/// interrupt 是同一個道理），遇到時安全退化成 `.stay` 並記一則 debug log，不會 crash、
/// 也不會讓對話狀態卡在半調子的地方。
public struct AnyInterruptReturnHandler: Sendable {
    let invoke: @Sendable (
        _ resultData: Data,
        _ parentStateData: Data,
        _ parentSessionData: Data,
        _ parentSceneName: String,
        _ chatID: Int64,
        _ userID: Int64?,
        _ dependencies: SceneDependencies
    ) async throws -> (
        transition: TransitionKind,
        newState: Data?,
        newSession: Data,
        newHistory: [Data],
        suspended: SuspendedScene?,
        interruptingScene: AnyScene?,
        resultData: Data?
    )

    public init<State: ConversationState, Session: Codable & Sendable, Result: Codable & Sendable>(
        _ onReturn: @escaping @Sendable (Result, Context<State, Session>) async throws -> Transition<State>
    ) {
        self.invoke = { resultData, parentStateData, parentSessionData, parentSceneName, chatID, userID, dependencies in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()

            // 這裡的 state／session 是父流程被中斷當下存下來的，不是「可能不存在、要退化成
            // initial」的情境（跟 AnyScene._resume 一開始那個 fallback 不一樣）——如果 decode
            // 失敗代表資料本身壞了，直接往上拋，交給 dispatch 既有的 catch block 處理。
            let result = try decoder.decode(Result.self, from: resultData)
            let state = try decoder.decode(State.self, from: parentStateData)
            let session = try decoder.decode(Session.self, from: parentSessionData)

            let ctx = Context<State, Session>(
                chatID: chatID,
                userID: userID,
                text: nil,
                callbackData: nil,
                session: session,
                sceneName: parentSceneName,
                apiClient: dependencies.apiClient,
                scheduler: dependencies.scheduler,
                engine: dependencies.engine,
                logger: dependencies.logger
            )

            let transition = try await onReturn(result, ctx)

            switch transition {
            case .transition(to: let newState):
                return (.moved, try encoder.encode(newState), try encoder.encode(ctx.session), [], nil, nil, nil)
            case .stay:
                return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), [], nil, nil, nil)
            case .end:
                return (.ended, nil, try encoder.encode(ctx.session), [], nil, nil, nil)
            case .endWithResult(let data):
                return (.ended, nil, try encoder.encode(ctx.session), [], nil, nil, data)
            case .rollback:
                // 中斷當下的 stateHistory 本來就沒有保留（見 AnyScene 既有的 .interrupt 分支
                // 的說明），這裡自然也沒有更早的步驟可以退，統一退化成 .stay。
                return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), [], nil, nil, nil)
            case .interrupt, .interruptWithReturn:
                dependencies.logger.debug("AnyInterruptReturnHandler: onReturn 回傳 .interrupt 不支援，退化成 .stay")
                return (.stayed, try encoder.encode(state), try encoder.encode(ctx.session), [], nil, nil, nil)
            }
        }
    }
}
