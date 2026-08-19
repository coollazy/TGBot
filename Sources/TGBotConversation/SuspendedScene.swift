import Foundation

/// scene 棧裡「被暫停」的一筆記錄：暫停時的 scene 本身（型別已擦除）加上暫停當下的
/// state／session（同樣以 Data 編碼），interrupt 結束後用來原地恢復。
///
/// 存取層級更正：因為是 `ChatConversationRecord.sceneStack`（public，見該檔案說明）的
/// 元素型別，被迫跟著改為 public，理由與 AnyScene 相同。
public struct SuspendedScene: Sendable {
    public let scene: AnyScene
    public let savedState: Data
    public let savedSession: Data
    /// 非 nil 代表這次中斷是用 `.interrupt(with:onReturn:)` 觸發的——子流程用
    /// `.end(with:)` 帶結果結束時，會呼叫這個 handler 把結果交回來；nil 代表舊版純中斷
    /// （或沒有註冊 onReturn），恢復時只走 `onResume` 那條路徑。
    public let returnHandler: AnyInterruptReturnHandler?

    public init(
        scene: AnyScene,
        savedState: Data,
        savedSession: Data,
        returnHandler: AnyInterruptReturnHandler? = nil
    ) {
        self.scene = scene
        self.savedState = savedState
        self.savedSession = savedSession
        self.returnHandler = returnHandler
    }
}
