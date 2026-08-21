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
資料 + inline 按鈕 + 條件分支 + 照片／檔案收送），這裡只列最精簡的骨架：

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

### 照片／檔案收送範例：`/upload`

同樣在 `Example/` 裡，`makeUploadScene()`——傳一張照片會用 `ctx.photo.fileID` 透過
`.fileID(_:)` 原樣轉發回去（不用自己下載再重新上傳）；傳一般檔案則會示範
`ctx.downloadFile(_:)` 真的把內容抓下來、回報下載到的 bytes 數量。對應 README 上面
「收送照片／檔案」那段程式碼片段的完整可執行版本。

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
- `ctx.photo` / `ctx.document`：使用者這次傳來的照片／檔案（`IncomingFile?`，沒有就是 nil）
- `ctx.session`：讀寫這段流程累積的資料
- `ctx.reply(_:)` / `ctx.replyWithMenu(_:buttons:)`：回訊息
- `ctx.replyWithPhoto(_:caption:)` / `ctx.replyWithDocument(_:caption:)`：送照片／檔案
- `ctx.downloadFile(_:)`：下載 `ctx.photo`／`ctx.document` 指到的檔案內容
- `ctx.startBackgroundJob(id:work:onComplete:)`：啟動不卡住對話的長任務。任務執行期間
  如果使用者透過正常訊息又編輯過 session，任務完成時會保留使用者較新的那份，不會被
  任務啟動當下那份舊的 session 覆蓋（`onComplete` 決定的狀態轉移仍然照常套用，只有
  session 資料的部分會這樣處理）
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

### 收送照片／檔案

送出的來源用 `TGFileSource` 表示，三種都支援：

```swift
.fileID("AgACAgIA...")                              // 重用 Telegram 已有的 file_id，最省流量
.url("https://example.com/cat.png")                 // 讓 Telegram 伺服器自己去抓公開網址
.data(pngData, filename: "cat.png", mimeType: "image/png")  // 直接上傳本地端產生的檔案內容
```

送出：

```swift
scene.on(.confirm) { ctx in
    try await ctx.replyWithPhoto(.url("https://example.com/cat.png"), caption: "你的貓咪")
    try await ctx.replyWithDocument(.data(pdfData, filename: "invoice.pdf", mimeType: "application/pdf"))
    return .end
}
```

接收：使用者傳照片／檔案時，`ctx.photo` / `ctx.document` 會是對應的 `IncomingFile?`（照片
自動取最大尺寸那張），用 `ctx.downloadFile(_:)` 拿實際內容：

```swift
scene.on(.waitingForReceipt) { ctx in
    guard let document = ctx.document else {
        try await ctx.reply("請傳收據檔案")
        return .stay
    }
    let data = try await ctx.downloadFile(document)
    // data 是 Data，document.fileName／document.mimeType 可用來判斷檔案類型
    return .end
}
```

## 測試你自己的對話流程

`TelegramAPIClient`、`StateStore`、`BackgroundTaskScheduling`、`AccessPolicy` 都是 protocol，
可以在測試裡用假的實作取代，完全不需要連上真實的 Telegram 服務——這個 repo 自己的測試
（`swift test`）就是這樣寫的，可以參考 `Tests/` 底下的既有範例。

可執行的完整版本在 [`Example/Tests/EchoBotExampleTests/UploadSceneTests.swift`](Example/Tests/EchoBotExampleTests/UploadSceneTests.swift)
（`cd Example && swift test` 就能跑），測的是 `Example` 裡真正的 `/upload` scene，不是另外
掰的玩具範例。重點是：不要透過 `TGBot` 這個門面類別測（它內部的 `ConversationEngine` 是
`private`，沒開放 `dispatch(update:)`），而是自己組一份 `EngineRegistry` + `ConversationEngine`，
把要測的 `Scene` 註冊上去，直接呼叫 `dispatch(update:)` 餵一筆手動建的 `Update` 進去，
斷言假的 `apiClient` 收到了什麼：

```swift
import Testing
import TGBot   // 開發者的機器人專案本身 import 的就是這個

final class FakeAPIClient: TelegramAPIClient, @unchecked Sendable {
    private(set) var sentMessages: [(chatID: Int64, text: String)] = []
    func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
        sentMessages.append((chatID, text))
    }
    func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
    func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
    func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {}
    func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws {}
    func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws {}
}

struct NoOpScheduler: BackgroundTaskScheduling {
    func start(chatID: Int64, taskID: String,
               work: @escaping @Sendable (JobProgress) async throws -> Void,
               onComplete: @escaping @Sendable (JobResult) async throws -> Void) async {}
    func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
}

@Test("問候流程回覆正確的名字")
func greetsUserByName() async throws {
    let apiClient = FakeAPIClient()
    let registry = EngineRegistry()
    let engine = ConversationEngine(
        stateStore: InMemoryStateStore(),
        apiClient: apiClient,
        scheduler: NoOpScheduler(),
        logger: Logger(label: "test"),
        registry: registry
    )
    registry.registerScene(myGreetScene, commandTrigger: "greet")  // 你自己 bot 裡的 scene

    await engine.dispatch(update: Update(chatID: 1, text: "/greet", commandName: "greet"))
    await engine.dispatch(update: Update(chatID: 1, text: "小明"))

    #expect(apiClient.sentMessages.last?.text == "哈囉，小明！")
}
```

多步驟流程、按鈕點擊（`callbackData:`）、照片/檔案（`photo:`/`document:`）都是同一招——
手動建 `Update` 餵進去，斷言假的 `apiClient` 收到什麼；`UploadSceneTests.swift` 裡就示範了
照片與檔案兩種附件的版本。

## 已知限制

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
