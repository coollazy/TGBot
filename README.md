# TGBot

一套 Swift Package，讓工程師能開發 Telegram 機器人。核心價值在於簡化「連續對話」與
「選單互動」這兩件事，開發者不需要自己從零設計對話狀態管理機制——註冊每個步驟該問
什麼、該怎麼往下走，剩下的（使用者現在在哪一步、按鈕點擊怎麼接回對話流程）交給
TGBot 處理。

完整需求與設計脈絡見 [`Docs/TGBot-需求書.html`](Docs/TGBot-需求書.html) 與
[`Docs/TGBot-架構設計.html`](Docs/TGBot-架構設計.html)。

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

如果是在這個 repo 本身底下開發、順便寫一個依賴它的 bot（例如 `Example/` 的做法），
用本地路徑依賴會比較方便，改動 library 馬上就看得到效果，不用等 push：

```swift
dependencies: [
    .package(path: "../TGBot")
]
```

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
image 丟到 Linux 上跑（例如驗證長時間輪詢的穩定度，而不是只在本機跑幾分鐘）：

```bash
cd Example
cp .env.example .env   # 編輯 .env，填入你自己的 TGBOT_TOKEN
docker compose up --build
```

兩階段建置（`swift:6.2-jammy` 編譯、`swift:6.2-jammy-slim` 只跑執行檔），image 比較小；
`docker-compose.yml` 預設 `restart: unless-stopped`，process 意外結束會自動重啟。細節
（尤其是 build context 為什麼是上一層、WORKDIR 名稱為什麼不能隨便取）見 `Example/Dockerfile`
開頭的註解——這兩個是實際建置踩過的坑，不是憑空預防性寫的。

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

### 跨聊天室真正並行處理

**現況**：`ConversationEngine`（`Sources/TGBotConversation/ConversationEngine.swift`）是單一個
actor，處理所有聊天室的事件。同一個聊天室的事件保證依序執行（正確性沒問題），但不同聊天室
之間的 `dispatch(update:)` 呼叫是排隊處理的，不是真的同時執行——如果 A 聊天室的某次呼叫
卡在一個很慢的操作上（例如 handler 裡呼叫了一個很慢的外部 API），B 聊天室的事件要等 A
處理完才會開始，即使兩者完全無關。

**為什麼現在不做**：需求書第 5 節「使用規模」已經明訂 v1 是「少量使用者，非高併發場景」，
在這個規模下，單一 actor 排隊處理實際上不太會被使用者感覺到延遲；而要做到真正的跨聊天室
並行，工作量跟風險是這次盤點出的所有缺口裡最高的一項（見下方「以後要做的話」），權衡下來
先不排入範圍。

**以後要做的話**：核心方向是把「一個 actor 處理所有 chat」拆成「依 chatID 分派到不同 actor」，
可能的做法包括：
- 一個 chatID → actor 的對照表，每個聊天室第一次出現時動態建立一個新 actor（要處理
  「多久沒有活動就可以把這個 actor 回收掉」，不然聊天室一多記憶體會一直長）
- 或固定數量的 actor pool，用 `chatID % N` 之類的方式分派（少了動態建立/回收的複雜度，
  但要挑一個合理的 N，也要接受同一個 pool slot 裡的不同 chatID 還是會互相排隊）

不管哪種做法，都要重新檢視現在依賴「所有東西共用同一個 actor」這件事的地方，至少包括：
`pendingCompletions`（背景任務完成回呼字典）、`chatTails`／序列化用的內部狀態如果之後有加的話，
確保拆開之後每個 chatID 各自的資料還是正確地綁在對的 actor 上，不會互相污染。

### 子流程結果傳回被中斷的流程（`onReturn` 不能再串接新的 interrupt）

**現況**：`Transition.interrupt(with:)` 支援暫停目前的流程、跑一個獨立的子流程，子流程
`.end` 之後自動恢復原本被中斷的地方繼續。子流程如果需要把收集到的資料交還給被中斷的
流程（例如一個「收集地址」的子流程，結束後主流程要能直接讀到使用者填的地址），用
`.interrupt(with:onReturn:)` 這個重載——子流程用 `.end(with:)` 帶著型別化的結果結束時，
會自動呼叫 `onReturn`，開發者在裡面決定拿到結果後接下來要做什麼（存進 session、回話、
繼續往下走一個 state、甚至再 `.end(with:)` 讓結果繼續往更上層被中斷的流程傳）。見
`Sources/TGBotConversation/Transition.swift`、`AnyInterruptReturnHandler.swift`，
`Example/` 的「填地址」子流程（在 `/profile` 問年齡時輸入「填地址」）是一個端對端的範例。

沒有帶結果需求的子流程（例如唯讀查詢型，`Example` 的「小提示」）維持用原本的
`.interrupt(with:)`（不帶 `onReturn`），行為完全不變。

**殘留的限制**：`onReturn` 回傳的 `Transition` 裡如果又是 `.interrupt(...)`（想在拿到
結果後立刻再岔去跑下一個子流程），不支援——會安全退化成 `.stay` 並記一則 debug log，
不會 crash、也不會卡在半調子的狀態，但也不會如預期地串起下一個子流程。

**為什麼現在不做**：這跟既有的「背景任務完成觸發 `.interrupt` 不支援」是同一種限制：
自動觸發的路徑（子流程結束、或背景任務完成）都不支援連續觸發新的 interrupt，只有
「使用者真的送出一則新訊息」這條路徑才能觸發 interrupt。要讓 `onReturn` 也能安全地
再次 `.interrupt`，需要在 `onReturn` 內部拿到「目前這個（父）scene 本身」才能重新包一個
`SuspendedScene`——但 `onReturn` 是透過 `Transition.interrupt(with:onReturn:)` 這個
靜態方法建構的，這個時間點還沒有「目前這個 scene」的參照可以捕捉，要解決的話得改變
`.interrupt(with:onReturn:)` 的呼叫方式（例如改成 `Scene` 的 instance method 而非
`Transition` 的靜態方法），影響範圍比這次的核心需求（資料交還）大，先不在這次的範圍內。

**現在的暫時解法**：需要在拿到子流程結果後立刻串下一個子流程的話，讓 `onReturn` 把結果
存好、`.stay`，交給下一次使用者真的送訊息時，由正常的 `on(state)` handler 再觸發下一個
`.interrupt`——不如「onReturn 直接串接」順手，但不需要繞道外部共享狀態。

**以後要做的話**：把 `.interrupt(with:onReturn:)` 改成能拿到「目前這個 scene」參照的
呼叫方式，讓 `onReturn` 內部也能安全建構 `SuspendedScene`，重用既有的 `.interrupted`
處理邏輯。
