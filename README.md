# TGBot

一套 Swift Package，讓工程師能開發 Telegram 機器人。核心價值在於簡化「連續對話」與
「選單互動」這兩件事，開發者不需要自己從零設計對話狀態管理機制——註冊每個步驟該問
什麼、該怎麼往下走，剩下的（使用者現在在哪一步、按鈕點擊怎麼接回對話流程）交給
TGBot 處理。

## 安裝

Repo 在 [github.com/coollazy/TGBot](https://github.com/coollazy/TGBot)，用一般的 URL 依賴：

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/coollazy/TGBot.git", branch: "master")
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

還沒有正式 release tag，先用 `branch: "master"` 追蹤主線；之後有 tag 了可以換成
`.upToNextMajor(from:)` 之類的版本鎖定寫法。

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

### 用 Docker 跑 Example

`Example/` 底下有 `Dockerfile`／`docker-compose.yml`／`.env.example`，可以直接打包成
image 丟到 Linux 上跑：

```bash
cd Example
cp .env.example .env   # 編輯 .env，填入你自己的 TGBOT_TOKEN
docker compose up --build
```

兩階段建置（先用完整版 Swift 編譯、再換成只有 runtime 的精簡版本執行），image 比較小；
`docker-compose.yml` 預設 `restart: unless-stopped`，process 意外結束會自動重啟。

### 更複雜的範例：`/menu`

`Example/` 裡除了 `/profile` 那組，還有一組獨立的 `/menu`——主選單（註冊／建立活動／設定）、
每個子流程都是獨立的 Scene，用 `.interrupt(with:)`／`.interrupt(with:onReturn:)` 中斷帶進去。
比 `/profile` 複雜得多，用來示範：

- 每個欄位都是 `onEnter`（顯示提示）／`on`（驗證答案）乾淨拆開的寫法
- 確認才把資料帶回主流程、取消不帶回（`.interrupt(with:onReturn:)` + 舊版 `.end`）
- 背景任務進度用「使用者主動問才回答」（`ctx.backgroundJobStatus`），不是主動推播
- 巢狀 `.interrupt`：設定子流程用 `AnyScene(_:initialSession:)` 把主流程現有的資料帶進去，
  設定自己底下的顯示畫面又再帶著這份資料往下傳一層

## 核心型別

### `TGBot`

對外統一入口，組裝所有內部模組。開發者只需要 `import TGBot` 這一個 module。

- `register(_:trigger:description:)` 註冊多步驟對話
- `onCommand(_:handler:)` 註冊全域指令
- `onUnhandled(_:)` 設定沒命中任何流程時的 fallback
- `onError(_:)` 接住 handler 拋出的錯誤

### `Scene<State, Session>`

一段多步驟對話流程。

- `State`：你自訂、遵循 `ConversationState` 的 enum，代表流程走到哪一步
- `Session`：這段流程累積收集的資料（例如姓名、年齡）
- `.on(state) { ctx in ... }` 收到使用者真的傳來的 Update 時觸發，驗證答案、決定轉移到哪
- `.onEnter(state) { ctx in ... }`（選配）轉移進入這個 state 的當下自動觸發，不用等
  使用者說話——用來顯示這個 state 的提示/選單，或做純判斷/計算後直接轉移下一步（回傳
  `.stay` 才會真的停下來等使用者輸入；回傳其他情況會不等使用者、立刻連鎖處理下一個
  transition）。沒註冊的話行為跟原本一樣，`on(state)` 直接處理進場當下那筆 Update。

### `Context<State, Session>`

handler 實際拿到的參數。

- `ctx.text` / `ctx.callbackData`：讀使用者的輸入
- `ctx.session`：讀寫這段流程累積的資料
- `ctx.reply(_:)` / `ctx.replyWithMenu(_:buttons:)`：回訊息
- `ctx.startBackgroundJob(id:work:onComplete:)`：啟動不卡住對話的長任務
- `ctx.backgroundJobStatus(id:)`：查詢任務進度

### `Transition<State>`

handler 的回傳值，決定流程接下來怎麼走。

- `.transition(to:)` 前進到下一步
- `.stay` 留在原地（例如輸入驗證失敗要求重試）
- `.end` 結束整段流程

### `InlineButton`

`replyWithMenu(_:buttons:)` 用的按鈕。使用者點擊後 `ctx.callbackData` 會直接拿到你設定的
`callbackData`，不需要自己比對是哪個按鈕被按下。框架也會自動處理 Telegram 規定的
`answerCallbackQuery` 確認、以及把點過的舊按鈕自動失效，開發者不用管這些細節。

## 測試你自己的對話流程

`TelegramAPIClient`、`StateStore`、`BackgroundTaskScheduling`、`AccessPolicy` 都是 protocol，
可以在測試裡用假的實作取代，完全不需要連上真實的 Telegram 服務——這個 repo 自己的測試
（`swift test`）就是這樣寫的，可以參考 `Tests/` 底下的既有範例。

## 已知限制

### 跨聊天室的訊息會互相排隊

目前所有聊天室的訊息是依序處理的，不同聊天室之間不會真的同時執行——如果某個聊天室的
handler 卡在一個很慢的操作上（例如呼叫了很慢的外部 API），其他聊天室的訊息要等它處理完
才會開始，即使兩者完全無關。設計上是給「少量使用者、非高併發」的場景用的；如果你的
bot 預期會有大量聊天室同時活躍、且 handler 裡有可能長時間卡住的操作，這點目前需要自己
注意（例如把慢速操作丟進 `ctx.startBackgroundJob(...)`，不要讓它卡住 handler 本身）。

### `onReturn` 不能直接再觸發下一個子流程

`.interrupt(with:onReturn:)` 讓子流程結束時把結果帶回中斷它的流程（見上面「核心型別」
或 `Example` 的「填地址」示範）。但 `onReturn` 裡如果直接回傳另一個 `.interrupt(...)`，
目前不支援——會安全地什麼都不做（不會 crash），但也不會如預期地接著跑下一個子流程。
需要串起兩個子流程的話，讓 `onReturn` 先把結果存好、正常結束，等使用者下一次真的傳訊息
過來，再由正常的 state handler 觸發下一個 `.interrupt`。

### 背景任務完成觸發的轉移，`onEnter` 不能再連續觸發 `.interrupt`

`ctx.startBackgroundJob(...)` 的 `onComplete` 回傳 `.transition(to:)` 時，轉移到的 state
如果有註冊 `onEnter`，會自動觸發（不用等使用者下一句話）。但如果那個 `onEnter` 又回傳
`.interrupt(...)`，這條路徑不支援——會安全地忽略、記一則 debug log，不會 crash。跟
`onReturn` 不能連續觸發下一個 `.interrupt`是同一種限制：自動觸發的路徑（背景任務完成、
子流程結束帶結果回來）都不支援連續觸發新的 interrupt，只有「使用者真的送出一則新訊息」
這條路徑才能觸發 `.interrupt`。
