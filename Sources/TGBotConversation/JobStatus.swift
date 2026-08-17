/// 查詢背景任務目前狀態用（例如 /status 指令）。見架構設計文件第 7 節。
public struct JobStatus: Sendable {
    public let taskID: String
    public let lastMessage: String
    public let isFinished: Bool

    public init(taskID: String, lastMessage: String, isFinished: Bool) {
        self.taskID = taskID
        self.lastMessage = lastMessage
        self.isFinished = isFinished
    }
}
