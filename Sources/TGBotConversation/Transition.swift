import Foundation

/// Scene handler 執行完後回傳的結果，決定對話接下來怎麼走。見架構設計文件 6.1 節。
public enum Transition<State: ConversationState>: Sendable {
    case transition(to: State)
    case stay
    case rollback
    case interrupt(with: AnyScene)
    /// 內部管線用的 case，開發者不需要直接建構——用下面的
    /// `.interrupt(with:onReturn:)` 靜態方法即可。
    case interruptWithReturn(with: AnyScene, onReturn: AnyInterruptReturnHandler)
    case end
    /// 內部管線用的 case，開發者不需要直接建構——用下面的 `.end(with:)` 靜態方法即可。
    case endWithResult(Data)
}

extension Transition {
    /// 暫停目前的流程、跑一個獨立的子流程，並在子流程用 `.end(with:)` 帶結果結束時，
    /// 自動把結果交給 `onReturn`——回傳的 `Transition<State>` 會被當成這一輪的處理結果，
    /// 直接接回目前這個（被中斷的）流程繼續跑，支援 `.transition(to:)`／`.stay`／
    /// `.rollback`／`.end`（含 `.end(with:)`，可以繼續往更上層的被中斷流程傳）。
    ///
    /// 已知限制：`onReturn` 內部回傳 `.interrupt`／`.interrupt(with:onReturn:)` 不支援，
    /// 會安全退化成 `.stay`（見 `AnyInterruptReturnHandler`）——需要接著再跑下一個子流程的
    /// 話，讓 `onReturn` 存好資料、`.stay`，交給下一次使用者真的送訊息時由正常的
    /// `on(state)` handler 觸發。
    ///
    /// 子流程如果用的是沒帶結果的舊版 `.end`，`onReturn` 不會被呼叫（沒有結果可以給），
    /// 行為等同沒有註冊 `onReturn` 的 `.interrupt(with:)`。
    public static func interrupt<Session: Codable & Sendable, Result: Codable & Sendable>(
        with scene: AnyScene,
        onReturn: @escaping @Sendable (Result, Context<State, Session>) async throws -> Transition<State>
    ) -> Transition<State> {
        .interruptWithReturn(with: scene, onReturn: AnyInterruptReturnHandler(onReturn))
    }

    /// 結束目前的流程，並把 `result` 編碼帶出去——如果這個流程是被 `.interrupt(with:onReturn:)`
    /// 中斷帶進來的，被中斷的流程會自動收到這個結果（見該方法的說明）；如果不是（例如直接被
    /// 使用者用指令啟動），效果等同一般的 `.end`，`result` 沒有地方可以送達，會被忽略。
    public static func end<Result: Codable & Sendable>(with result: Result) throws -> Transition<State> {
        .endWithResult(try JSONEncoder().encode(result))
    }
}
