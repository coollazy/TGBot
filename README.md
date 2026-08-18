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

### 子流程結果不會自動傳回被中斷的流程

**現況**：`Transition.interrupt(with:)`（見 `Sources/TGBotConversation/AnyScene.swift`）
支援暫停目前的流程、跑一個獨立的子流程，子流程 `.end` 之後也會自動恢復原本被中斷的地方
繼續（包含可選的 `Scene.onResume(_:handler:)` hook，讓開發者在恢復當下主動交代現在在等
什麼）。但子流程執行過程中收集到的資料，不會自動交還給被中斷的那個流程——例如一個「收集
地址」的子流程，使用者填完地址之後，主流程沒有辦法直接讀到「使用者剛剛填的地址是什麼」。

**為什麼現在不做**：這是刻意跟使用者確認過的最小版本範圍——「自動恢復」跟「資料交還」是
兩件複雜度差很多的事，前者只需要記住「暫停當下的 state/session」，後者需要設計一個
型別安全、跨兩個不同 State/Session 型別的資料傳遞機制，牽涉到的 API 設計問題比較大，
先不在這次的範圍內。

**現在的暫時解法**：如果真的需要子流程結果，開發者可以自己透過外部共享狀態繞過去（例如
把結果寫進一個開發者自己維護的字典，key 用 chatID，主流程恢復時自己去讀），不是框架
提供的能力，是繞道的做法。

**以後要做的話**：可能的方向是讓 `.interrupt(with:)` 除了子流程本身，還能帶一個
「子流程結束時要把什麼資料交還」的型別化管道，或是讓 `onResume` 除了通知「恢復了」，
也能拿到子流程留下的結果——確切的 API 長相還沒設計，需要额外的討論。
