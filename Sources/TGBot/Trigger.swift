/// scene 進入方式（bootstrapping）。見架構設計文件第 9 節。
public enum Trigger: Sendable {
    case command(String)
    // 之後可擴充，例如 .always（每個新 chat 一開始自動進入，不需要特定指令觸發）
}
