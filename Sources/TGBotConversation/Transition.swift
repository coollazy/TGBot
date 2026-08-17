/// Scene handler 執行完後回傳的結果，決定對話接下來怎麼走。見架構設計文件 6.1 節。
public enum Transition<State: ConversationState>: Sendable {
    case transition(to: State)
    case stay
    case rollback
    case interrupt(with: AnyScene)
    case end
}
