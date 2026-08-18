# TGBot

一套 Swift Package，讓工程師能開發 Telegram 機器人。核心價值在於簡化「連續對話」與
「選單互動」這兩件事，開發者不需要自己從零設計對話狀態管理機制——註冊每個步驟該問
什麼、該怎麼往下走，剩下的（使用者現在在哪一步、按鈕點擊怎麼接回對話流程）交給
TGBot 處理。

完整需求與設計脈絡見 [`Docs/TGBot-需求書.html`](Docs/TGBot-需求書.html) 與
[`Docs/TGBot-架構設計.html`](Docs/TGBot-架構設計.html)。

## 安裝

目前尚未發佈到任何 git host，用本地路徑依賴（跟 `Example/Package.swift` 的做法一樣）：

```swift
// Package.swift
dependencies: [
    .package(path: "../TGBot")
],
targets: [
    .executableTarget(
        name: "YourBot",
        dependencies: [
            .product(name: "TGBot", package: "TGBot")
        ]
    )
]
```

之後若推上 git host，改成一般的 URL 依賴即可，用法不變。

## 最小上手範例

完整、可執行的版本在 [`Example/`](Example)（一個真正獨立的 SwiftPM 專案，示範多步驟收集
資料 + inline 按鈕 + 條件分支），這裡只列最精簡的骨架：

```swift
import TGBot

enum GreetState: ConversationState {
    case askName
}

@main
struct MyBot {
    static func main() async throws {
        let bot = TGBot(configuration: .init(tokenFromEnv: "TGBOT_TOKEN"))

        let scene = Scene<GreetState, EmptySession>(name: "greet", initial: .askName)
        scene.on(.askName) { ctx in
            try await ctx.reply("哈囉，\(ctx.text ?? "陌生人")！")
            return .end
        }
        bot.register(scene, trigger: .command("greet"), description: "打招呼")

        try await bot.run()
    }
}
```

執行前設定環境變數：

```bash
export TGBOT_TOKEN="123456:AAAA-your-bot-token-from-BotFather"
swift run
```

## 核心型別

- **`TGBot`**：對外統一入口，組裝所有內部模組。開發者只需要 `import TGBot` 這一個 module。
  用 `register(_:trigger:description:)` 註冊多步驟對話、`onCommand(_:handler:)` 註冊全域指令、
  `onUnhandled(_:)` 設定沒命中任何流程時的 fallback、`onError(_:)` 接住 handler 拋出的錯誤。
- **`Scene<State, Session>`**：一段多步驟對話流程。`State` 是你自訂、遵循 `ConversationState`
  的 enum，代表流程走到哪一步；`Session` 是這段流程累積收集的資料（例如姓名、年齡）。
  用 `.on(state) { ctx in ... }` 為每個 state 註冊處理函式。
- **`Context<State, Session>`**：handler 實際拿到的參數，能讀 `ctx.text`／`ctx.callbackData`、
  讀寫 `ctx.session`、呼叫 `ctx.reply(_:)`／`ctx.replyWithMenu(_:buttons:)` 回訊息、用
  `ctx.startBackgroundJob(id:work:onComplete:)` 啟動不卡住對話的長任務、用
  `ctx.backgroundJobStatus(id:)` 查詢任務進度。
- **`Transition<State>`**：handler 的回傳值，決定流程接下來怎麼走——`.transition(to:)` 前進到
  下一步、`.stay` 留在原地（例如輸入驗證失敗要求重試）、`.end` 結束整段流程。
- **`InlineButton`**：`replyWithMenu(_:buttons:)` 用的按鈕，使用者點擊後 `ctx.callbackData`
  會直接拿到你設定的 `callbackData`，不需要自己比對是哪個按鈕被按下。框架也會自動處理
  Telegram 規定的 `answerCallbackQuery` 確認、以及把點過的舊按鈕自動失效，開發者不用管這些細節。

## 測試你自己的對話流程

`TelegramAPIClient`、`StateStore`、`BackgroundTaskScheduling`、`AccessPolicy` 都是 protocol，
可以在測試裡用假的實作取代，完全不需要連上真實的 Telegram 服務——這個 repo 自己的測試
（`swift test`）就是這樣寫的，可以參考 `Tests/` 底下的既有範例。

## 已知限制

v1 刻意先做能跑、能被驗證的核心路徑，以下幾項還沒做（詳見程式碼裡的對應註解）：

- `.rollback`：目前等同 `.stay`，不會真的退回先前的步驟。
- `.interrupt`：子流程組合機制，目前會 `fatalError`。
- 跨聊天室真正並行處理：目前是單一 actor 依序處理所有聊天室的事件（需求書已明訂
  v1 為非高併發場景，屬於刻意的取捨，不是 bug）。
