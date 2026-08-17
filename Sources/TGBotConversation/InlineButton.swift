/// 選單／Inline Keyboard 整合，見架構設計文件第 8 節。
public struct InlineButton: Sendable {
    public let text: String
    public let callbackData: String

    public init(text: String, callbackData: String) {
        self.text = text
        self.callbackData = callbackData
    }
}
