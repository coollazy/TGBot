import Foundation
import TGBot

/// 收集姓名／年齡／性別的多步驟對話流程範例，確認後依「性別 × 每 10 歲一個階層」
/// 回應不同的總結文字。示範：分支（依輸入是否合法決定 .stay 還是往下走）、
/// 用 inline 按鈕收集選項（callback_query 那條路徑）、多步驟 session 累積資料、
/// 流程中途插入一個長任務（確認後「產生總結」模擬成要跑 5 秒的背景任務，這段期間
/// bot 仍可正常回應其他訊息，任務完成後才送出總結、結束流程）、在被問年齡時輸入
/// 「上一步」可以體驗 Transition.rollback 真的退回上一步（重新輸入名字），不是原地不動。
///
/// 另外示範兩種不同用途的 Transition.interrupt 子流程：輸入「小提示」是**唯讀查詢型**——
/// 暫停填資料的流程、岔去跑一個完全獨立的小提示子流程，不需要子流程回傳任何資料，結束後
/// 自動接回原本填到一半、沒填完的地方繼續；輸入「填地址」則是**資料收集型**——子流程要
/// 收集地址、還要把收集到的結果帶回填資料這個主流程繼續用（用 `.interrupt(with:onReturn:)` +
/// `.end(with:)`），這才是子流程真正常見的用法。
///
/// 這是獨立於 TGBot library 本身的 SwiftPM 專案（見 ../Package.swift 用 local path
/// 依賴），只 `import TGBot` 這一個 module——刻意模擬真正外部開發者的使用情境。
///
/// 執行方式：
///   export TGBOT_TOKEN="你的 bot token（跟 @BotFather 申請）"
///   swift run
/// 對機器人輸入 /profile 開始。
@main
struct EchoBotExample {
    enum ProfileState: ConversationState {
        case askName
        case askAge
        case askGender
        case confirmDetails
        case finished
        case generating
    }

    struct ProfileData: Codable {
        var name: String?
        var age: Int?
        var gender: String? // "male" / "female"
        var address: String? // 由「填地址」子流程透過 .interrupt(with:onReturn:) 帶回來
    }

    static func main() async throws {
        // Bot Token：這裡示範用環境變數提供（見架構設計文件第 9／13 節的 Bot Token 配置決策）。
        let configuration = TGBot.Configuration(tokenFromEnv: "TGBOT_TOKEN")

        guard !configuration.token.isEmpty else {
            print("""
            請先設定環境變數 TGBOT_TOKEN 再執行這個範例，例如：

              export TGBOT_TOKEN="123456:AAAA-your-bot-token-from-BotFather"
              swift run
            """)
            return
        }

        let bot = TGBot(configuration: configuration)

        // 小提示子流程：填 /profile 填到一半可以用「小提示」中斷進來，本身不開放使用者
        // 直接打指令啟動，所以 trigger 給 nil——register(_:trigger:description:) 不管
        // 有沒有給 trigger 都會正確註冊，讓中斷帶進來的 scene 能撐過後續每一輪對話，
        // 不需要為了「能被中斷用」而掰一個用不到的指令出去。
        // 建一次、兩邊共用同一個實例，不要各自各建一個同名但不同物件的 scene。
        let tips = makeTipsScene()
        bot.register(tips)

        // 填地址子流程：結束時會帶著使用者填的地址回去給 /profile（見 .askGender 裡的
        // 「填地址」判斷），不是單純的唯讀查詢，但一樣不需要開放指令直接啟動。
        let address = makeAddressScene()
        bot.register(address)

        let profile = makeProfileScene(tipsScene: tips, addressScene: address)
        bot.register(profile, trigger: .command("profile"), description: "開始填寫個人資料")

        // 照片／檔案收送範例：獨立於 /profile、/menu 之外，示範 ctx.photo／ctx.document
        // 怎麼收、ctx.downloadFile(_:) 怎麼下載內容、ctx.replyWithPhoto(_:) 怎麼用收到的
        // file_id 直接轉發回去（不用重新上傳一次）。
        let upload = makeUploadScene()
        bot.register(upload, trigger: .command("upload"), description: "示範收送照片／檔案")

        // 主選單／註冊／建立活動／設定：完全獨立於 /profile 的另一組範例，見
        // MenuExample.swift 開頭的說明——只有主選單開放指令觸發，其餘子流程都只能被
        // 中斷帶進去（trigger: nil）。要先建好被依賴的子流程，才能建主選單。
        let showProfile = MenuExample.makeShowProfileScene()
        bot.register(showProfile)
        let showEvents = MenuExample.makeShowEventsScene()
        bot.register(showEvents)
        let settings = MenuExample.makeSettingsScene(showProfileScene: showProfile, showEventsScene: showEvents)
        bot.register(settings)
        let registerHelp = MenuExample.makeRegisterHelpScene()
        bot.register(registerHelp)
        let register = MenuExample.makeRegisterScene(helpScene: registerHelp)
        bot.register(register)
        let createEvent = MenuExample.makeCreateEventScene()
        bot.register(createEvent)
        let mainMenu = MenuExample.makeMainMenuScene(registerScene: register, createEventScene: createEvent, settingsScene: settings)
        bot.register(mainMenu, trigger: .command("menu"), description: "多層選單範例（註冊／建立活動／設定）")

        // 全域指令：取消目前流程（US-5），description 會自動同步進 Telegram 的指令選單。
        bot.onCommand("cancel", description: "取消目前進行中的流程") { ctx in
            await ctx.resetConversation()
            try await ctx.reply("已取消，若要重新開始請再次輸入 /profile 或 /menu。")
        }

        // 示範 parse_mode: .html——ctx.reply(_:parseMode:) 可以送 Telegram 認得的 HTML
        // 標籤，最常見的用途是讓連結可以直接點擊（例如公告訊息裡的 MR 連結），而不是只能
        // 貼一整串裸網址讓使用者自己複製。同一段文字如果不帶 parseMode，Telegram 會把
        // <a>、<b> 這些標籤原封不動當純文字顯示出來，兩則訊息放在一起最容易看出差異。
        bot.onCommand("html", description: "示範 parse_mode: .html（可點擊連結／粗體／斜體）") { ctx in
            let htmlText = """
            這是一則用 <b>parse_mode: .html</b> 送出的訊息：
            👉 <a href="https://github.com">可點擊連結</a>
            <b>粗體</b>、<i>斜體</i>、<code>行內程式碼</code> 都吃得到。
            """
            try await ctx.reply(htmlText, parseMode: .html)

            // 對照組：完全相同的文字但不帶 parseMode，Telegram 只會把它當純文字顯示，
            // 標籤會直接露出來——兩則放在一起比較最直觀。
            try await ctx.reply("對照組（不帶 parseMode，標籤會原樣顯示）：\n" + htmlText)
        }

        // 示範 parse_mode: .markdownV2——跟上面的 .html 是同一個機制，只是換一種 Telegram
        // 認得的標記語法：*粗體*、_斜體_、`行內程式碼`、[文字](網址)。MarkdownV2 對一組保留
        // 字元（. ! _ - 等等，用在格式標記以外的地方時）要求明確跳脫（\. 、\_），不然
        // Telegram 會直接回 400 拒收整則訊息，錯誤訊息只會說 can't parse entities，不會告訴你
        // 是哪個字元漏跳脫——這裡兩處都是刻意示範，不是打錯字：句號寫成 \.；而
        // 「parse\_mode」裡的底線也得跳脫，不然會被誤判成沒配對成功的斜體標記，害外層的
        // *粗體* 也跟著抓不到正確的結尾（本地實測到的真實錯誤：Can't find end of Bold entity）。
        bot.onCommand("markdown", description: "示範 parse_mode: .markdownV2（粗體／斜體／連結）") { ctx in
            let markdownText = """
            這是一則用 *parse\\_mode: \\.markdownV2* 送出的訊息：
            👉 [可點擊連結](https://github.com)
            *粗體*、_斜體_、`行內程式碼` 都吃得到\\.
            """
            try await ctx.reply(markdownText, parseMode: .markdownV2)
        }

        // 示範 disableWebPagePreview：連結一樣可點，但不會自動展開成下面那張大預覽卡片
        // ——訊息裡有多個連結、或連結只是附帶提及、不想讓卡片喧賓奪主的時候適用。
        bot.onCommand("nopreview", description: "示範 disableWebPagePreview（連結可點但不展開預覽卡片）") { ctx in
            let text = "👉 <a href=\"https://github.com\">可點擊連結</a>（這則沒有預覽卡片）"
            try await ctx.reply(text, parseMode: .html, disableWebPagePreview: true)

            // 對照組：完全相同的文字，但沒有帶 disableWebPagePreview，會照舊自動展開卡片。
            try await ctx.reply("對照組（沒帶 disableWebPagePreview，照舊展開卡片）：\n" + text, parseMode: .html)
        }

        print("TGBot 範例已啟動，對機器人輸入 /profile、/menu 或 /upload 開始。")
        try await bot.run()
    }

    /// 問年齡時附上的三個捷徑按鈕（上一步／小提示／填地址）——年齡本身還是要打字輸入
    /// 數字，這三個是原本設計成打字指令（「上一步」／「小提示」／「填地址」）的岔路，
    /// 改成按鈕點選比較不會被使用者忘記怎麼打。這組按鈕會在三個地方重複用到（剛問年齡、
    /// 從小提示子流程回來、從填地址子流程回來），所以抽成一個共用的 helper。
    static var ageStepShortcutButtons: [[InlineButton]] {
        [[
            InlineButton(text: "上一步", callbackData: "rollback"),
            InlineButton(text: "小提示", callbackData: "tips"),
            InlineButton(text: "填地址", callbackData: "address"),
        ]]
    }

    /// 問年齡那則訊息的文字，跟 ageStepShortcutButtons 一樣要在三個地方重複用到
    /// （剛問年齡、編輯回「已選擇」、從子流程回來重問）,抽成 helper 避免打錯字漏改到某一處。
    static func askAgePrompt(name: String?) -> String {
        "\(name ?? "你")幾歲呢？請直接輸入數字，或點選下面的按鈕："
    }

    /// 每個 state 的 handler 處理的是「回答了什麼東西才進到這個 state」，
    /// 再問下一個問題、轉移到下一個 state——例如 .askAge 的 handler 收到的
    /// ctx.text 其實是使用者對「你叫什麼名字？」的回答（名字），不是年齡；
    /// 進到 .askAge 這個 state 本身才是要問年齡。
    static func makeProfileScene(
        tipsScene: Scene<TipsState, EmptySession>,
        addressScene: Scene<AddressState, EmptySession>
    ) -> Scene<ProfileState, ProfileData> {
        let scene = Scene<ProfileState, ProfileData>(name: "profile", initial: .askName, initialSession: ProfileData())

        scene.on(.askName) { ctx in
            // 這是流程的入口，ctx.text 此時是觸發指令本身（/profile），不是答案，忽略即可
            try await ctx.reply("你好！我們先來填一下資料。請問你的名字是？")
            return .transition(to: .askAge)
        }

        scene.on(.askAge) { ctx in
            // 上一步問的是名字，這裡收到的就是名字
            ctx.session.name = ctx.text
            try await ctx.replyWithMenu(askAgePrompt(name: ctx.session.name), buttons: ageStepShortcutButtons)
            return .transition(to: .askGender)
        }

        scene.on(.askGender) { ctx in
            // 示範 US-2：Transition.rollback 現在真的會退回歷史棧記錄的「上一步」
            // （這裡是問名字、順便問年齡的那個 state），不是原地不動——點「上一步」
            // 就能重新輸入名字，年齡會用你重新輸入名字之後、下一次被問到時再填。
            // 同時保留打字「上一步」也能觸發，不強迫使用者一定要點按鈕。
            if ctx.text == "上一步" || ctx.callbackData == "rollback" {
                // 只有真的是點按鈕（callbackData 有值）才編輯原本那則訊息——如果是打字
                // 觸發的，ctx.messageID 指的是使用者自己送的那則訊息，bot 沒有權限編輯
                // 別人送的訊息，updateOriginalMessage 硬呼叫下去只會被 Telegram 拒絕。
                if ctx.callbackData != nil {
                    try await ctx.updateOriginalMessage("\(askAgePrompt(name: ctx.session.name))已選擇「上一步」↩️")
                }
                try await ctx.reply("好，我們重新來，請再輸入一次名字：")
                return .rollback
            }

            // 示範 US-1（唯讀查詢型子流程）：Transition.interrupt 讓填資料的流程可以暫停
            // 自己、岔去跑一個完全獨立的子流程（小提示），跟填資料本身無關，不需要子流程
            // 回傳任何資料；子流程結束後會自動接回這裡繼續問年齡，不是重新開始整個
            // /profile。之前這裡直接 fatalError，完全沒實作。
            if ctx.text == "小提示" || ctx.callbackData == "tips" {
                if ctx.callbackData != nil {
                    try await ctx.updateOriginalMessage("\(askAgePrompt(name: ctx.session.name))已選擇「小提示」💡")
                }
                return .interrupt(with: AnyScene(tipsScene))
            }

            // 示範 US-1（資料收集型子流程）：跟小提示不一樣，填地址子流程結束時真的有
            // 資料要交還——用 .interrupt(with:onReturn:) 帶一個型別化回調，子流程用
            // .end(with:) 結束時會自動被呼叫，拿到的 address 就是使用者在子流程裡填的
            // 地址，直接存進主流程自己的 session，不需要透過任何外部共享狀態繞過去。
            if ctx.text == "填地址" || ctx.callbackData == "address" {
                if ctx.callbackData != nil {
                    try await ctx.updateOriginalMessage("\(askAgePrompt(name: ctx.session.name))已選擇「填地址」📍")
                }
                return .interrupt(with: AnyScene(addressScene)) { (address: String, ctx: Context<ProfileState, ProfileData>) in
                    ctx.session.address = address
                    try await ctx.replyWithMenu(
                        "已收到地址：\(address)。我們繼續填資料：\(ctx.session.name ?? "你")幾歲呢？請輸入數字。",
                        buttons: ageStepShortcutButtons
                    )
                    return .stay
                }
            }

            // 上一步問的是年齡；輸入不合法就留在原地重試（對應 US-2：錯誤發生時退回重試）。
            // 按鈕點過一次就會被拿掉（框架自動處理），但打字打錯不會影響按鈕本身，不用
            // 每次重試都重新送一次按鈕。
            guard let text = ctx.text, let age = Int(text), age >= 0, age <= 150 else {
                try await ctx.reply("這個年齡看起來怪怪的，請輸入一個 0～150 之間的數字，或點選上面的按鈕。")
                return .stay
            }
            ctx.session.age = age

            try await ctx.replyWithMenu(
                "了解，請選擇性別：",
                buttons: [[
                    InlineButton(text: "男", callbackData: "male"),
                    InlineButton(text: "女", callbackData: "female"),
                ]]
            )
            return .transition(to: .confirmDetails)
        }

        scene.on(.confirmDetails) { ctx in
            // 上一步問的是性別，這裡透過按鈕的 callbackData 收到答案
            guard let gender = ctx.callbackData, gender == "male" || gender == "female" else {
                try await ctx.reply("請點選上面的按鈕選擇性別。")
                return .stay
            }
            ctx.session.gender = gender

            let genderLabel = gender == "male" ? "男" : "女"
            // 框架已經自動把「男／女」按鈕拿掉了，這裡額外把原本那則消息的文字也換成
            // 顯示選擇結果，體驗上比只是按鈕消失、什麼都沒交代要好
            try await ctx.updateOriginalMessage("了解，請選擇性別：已選擇 \(genderLabel) ✅")

            let name = ctx.session.name ?? "（未填寫）"
            let age = ctx.session.age.map(String.init) ?? "（未填寫）"
            // 有填地址（走過「填地址」子流程）才顯示這一行，沒填的話（沒體驗過子流程資料
            // 交還的示範）維持原本的三行確認畫面，不強迫使用者一定要走過那個子流程。
            let addressLine = ctx.session.address.map { "\n地址：\($0)" } ?? ""

            try await ctx.replyWithMenu(
                """
                請確認以下資料：
                姓名：\(name)
                年齡：\(age)
                性別：\(genderLabel)\(addressLine)
                """,
                buttons: [[InlineButton(text: "確認", callbackData: "confirm")]]
            )
            return .transition(to: .finished)
        }

        scene.on(.finished) { ctx in
            guard ctx.callbackData == "confirm" else {
                try await ctx.reply("請點選「確認」按鈕。")
                return .stay
            }
            guard let name = ctx.session.name, let age = ctx.session.age, let gender = ctx.session.gender else {
                try await ctx.reply("資料不完整，請輸入 /profile 重新開始。")
                return .end
            }

            // 跟性別選擇同一個道理：把確認畫面上的按鈕文字換成「已確認」，對話紀錄裡才
            // 看得出使用者當時點了確認，而不是按鈕原地消失、什麼都沒交代。
            let addressLine = ctx.session.address.map { "\n地址：\($0)" } ?? ""
            try await ctx.updateOriginalMessage(
                """
                請確認以下資料：
                姓名：\(name)
                年齡：\(age)
                性別：\(gender == "male" ? "男" : "女")\(addressLine)
                已確認 ✅
                """
            )

            // 示範 US-3／US-6：把「產生總結」模擬成一個要花 5 秒的長任務，這段期間你可以
            // 正常跟 bot 說其他的話，不會被卡住；任務完成後才真的送出總結文字並結束流程——
            // 這是 Phase 2 補的功能，之前 onComplete 回傳的 transition 會被直接丟掉，
            // 使用者永遠等不到這則總結（bot 會看起來像卡住了，其實是通知沒有真的接上）。
            //
            // 轉去 .generating 這個專門的「等待中」state，而不是留在 .finished 原地：
            // 如果留在原地，使用者這段期間傳的任何話都會被 .finished 的「請點選確認按鈕」
            // 判斷接住，變成很奇怪的體驗（明明已經確認過了，卻一直被叫去點確認按鈕）——
            // 這是實機測試才發現的落差。
            try await ctx.reply("產生總結中，請稍候（約 5 秒）...你可以先跟我說別的話，不會被卡住。")
            ctx.startBackgroundJob(id: "profile-summary", work: { progress in
                await progress.update("產生總結中")
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }, onComplete: { result, taskID, ctx in
                switch result {
                case .success:
                    try await ctx.reply(summaryText(name: name, age: age, gender: gender, address: ctx.session.address))
                case .failure:
                    try await ctx.reply("產生總結時發生問題，請輸入 /profile 重新開始。")
                }
                return .end
            })
            return .transition(to: .generating)
        }

        scene.on(.generating) { ctx in
            // 背景任務還在跑的期間，使用者傳的任何話都會進到這裡——給一個清楚交代進度的
            // 回覆，而不是誤導成別的意思。
            try await ctx.reply("總結還在產生中，完成後會主動通知你，請稍候。")
            return .stay
        }

        // 示範 US-1 的 onResume hook：從「小提示」子流程回來時，主動交代現在在等什麼，
        // 用開發者自己知道的措辭（使用者的名字、正在問年齡這件事），不是框架塞一句
        // 使用者看不懂「已回到某個 scene」的通用訊息——這是實機測試才發現的落差：
        // 沒有這個 hook 的時候，岔出去再回來，下一句話只會撞上驗證失敗的訊息
        // （「這個年齡看起來怪怪的」），聽起來像使用者答錯了，但其實只是被晾在那裡而已。
        scene.onResume(.askGender) { ctx in
            // 從小提示子流程回來——「小提示」按鈕本身點下去時，框架已經自動把原本問年齡
            // 那則訊息的按鈕拿掉了（見 dispatch 收到 callback_query 的處理），這裡要重新
            // 附上按鈕，不然「上一步」「填地址」這兩條捷徑就消失了。
            try await ctx.replyWithMenu(
                "好，我們繼續填資料：\(ctx.session.name ?? "你")幾歲呢？請輸入數字。",
                buttons: ageStepShortcutButtons
            )
        }

        return scene
    }

    enum TipsState: ConversationState {
        case menu
        case detail
    }

    /// 完全獨立於 /profile 的一個小流程：可以自己用 /tips 直接啟動，也可以被
    /// /profile 中斷帶進來（見 .askGender 裡的「小提示」判斷）。.menu 是入口，
    /// 忽略觸發用的文字（可能是「小提示」這句話，也可能是 /tips 指令本身），
    /// 直接顯示選單；.detail 處理按鈕點擊，回答完就 .end——如果是被中斷帶進來的，
    /// .end 之後 dispatch 會自動把原本被中斷的 /profile 接回去繼續問年齡。
    static func makeTipsScene() -> Scene<TipsState, EmptySession> {
        let scene = Scene<TipsState, EmptySession>(name: "tips", initial: .menu)

        scene.on(.menu) { ctx in
            try await ctx.replyWithMenu(
                "小提示：想看哪一個？",
                buttons: [[
                    InlineButton(text: "為什麼要收集這些資料？", callbackData: "why"),
                    InlineButton(text: "資料會怎麼被使用？", callbackData: "usage"),
                ]]
            )
            return .transition(to: .detail)
        }

        scene.on(.detail) { ctx in
            let question: String?
            let tip: String
            switch ctx.callbackData {
            case "why":
                question = "為什麼要收集這些資料？"
                tip = "這是示範 Transition.interrupt：填資料填到一半也能先岔開處理別的事，" +
                    "處理完會自動接回原本沒填完的地方繼續，不用重新開始。"
            case "usage":
                question = "資料會怎麼被使用？"
                tip = "這只是範例，不會真的把資料存到任何地方——bot 一重啟，資料就沒了。"
            default:
                question = nil
                tip = "請點選上面的按鈕。"
            }
            // 同樣把選單訊息換成「已選擇 XXX」，對話紀錄裡看得出點了哪一個問題；
            // 沒點按鈕（default 分支）就沒有原始訊息可以編輯，跳過。
            if let question {
                try await ctx.updateOriginalMessage("小提示：想看哪一個？已選擇「\(question)」")
            }
            try await ctx.reply(tip)
            return .end
        }

        return scene
    }

    enum AddressState: ConversationState {
        case askAddress
        case receiveAddress
    }

    /// 跟 tips 一樣完全獨立、可以自己用 /address 直接啟動，也可以被 /profile 中斷帶進來
    /// （見 .askGender 裡的「填地址」判斷）——但跟 tips 不同的地方是：這個子流程結束時
    /// 帶著的結果（使用者填的地址）會被中斷它的流程用 onReturn 接住繼續用，不是單純的
    /// 唯讀查詢。.askAddress 是入口（忽略觸發用的文字，直接問地址），.receiveAddress
    /// 收到答案後用 `.end(with:)` 把結果帶出去。
    static func makeAddressScene() -> Scene<AddressState, EmptySession> {
        let scene = Scene<AddressState, EmptySession>(name: "address", initial: .askAddress)

        scene.on(.askAddress) { ctx in
            try await ctx.reply("請輸入你的地址：")
            return .transition(to: .receiveAddress)
        }

        scene.on(.receiveAddress) { ctx in
            return try .end(with: ctx.text ?? "")
        }

        return scene
    }

    enum UploadState: ConversationState {
        case waitingForFile
    }

    /// 完全獨立的照片／檔案收送示範，用 /upload 直接啟動。傳一張照片或一個檔案都會被
    /// 原樣轉發回去（示範 ctx.photo／ctx.document 的 fileID 可以直接透過 .fileID(_:)
    /// 重用，不用自己下載再重新上傳一次）；檔案的部分額外示範真的下載內容
    /// （ctx.downloadFile(_:)），確認拿到的 bytes 數量對不對，證明拿到的是完整檔案、
    /// 不只是 metadata；兩者都沒傳就留在原地提醒使用者。
    static func makeUploadScene() -> Scene<UploadState, EmptySession> {
        let scene = Scene<UploadState, EmptySession>(name: "upload", initial: .waitingForFile)

        scene.on(.waitingForFile) { ctx in
            if let photo = ctx.photo {
                try await ctx.reply("收到照片（\(photo.fileSize.map(String.init) ?? "未知") bytes），原樣轉發給你：")
                // 重用使用者剛傳來的 file_id，不用自己下載內容再重新上傳一次。
                try await ctx.replyWithPhoto(.fileID(photo.fileID))
                return .end
            }

            if let document = ctx.document {
                // 真的把內容下載下來，證明 ctx.downloadFile(_:) 拿到的是完整檔案，不只是
                // metadata——實務上這裡會接著做存檔、解析內容等等，範例只做最簡單的確認。
                let data = try await ctx.downloadFile(document)
                try await ctx.reply("收到檔案「\(document.fileName ?? "未命名")」（\(document.mimeType ?? "未知類型")），下載到 \(data.count) bytes，轉發給你：")
                // 這裡一樣重用 file_id 轉發，不是把剛下載的 data 重新上傳——下載那步純粹是
                // 為了證明 downloadFile(_:) 真的拿得到內容，跟轉發用的是兩件獨立的事。
                try await ctx.replyWithDocument(.fileID(document.fileID))
                return .end
            }

            try await ctx.reply("請傳一張照片或一個檔案給我（也可以直接用聊天室裡的迴紋針按鈕）。")
            return .stay
        }

        return scene
    }

    /// 依「性別 × 每 10 歲一個階層」產生不同的總結文字，如果有地址（走過「填地址」子流程）
    /// 就一併帶上——證明子流程交還回來的資料不只是能存進 session，最後真的能被用在下游。
    static func summaryText(name: String, age: Int, gender: String, address: String? = nil) -> String {
        let bracketStart = (age / 10) * 10
        let bracketLabel = "\(bracketStart)～\(bracketStart + 9) 歲"
        let genderLabel = gender == "male" ? "男性" : "女性"

        let vibe: String
        switch bracketStart {
        case 0..<10:
            vibe = "還在成長階段，好好玩耍、好好長大最重要！"
        case 10..<20:
            vibe = "青少年時期，正是探索世界、培養興趣的黃金時間。"
        case 20..<30:
            vibe = "20 多歲，正是闖蕩世界、累積經驗的階段，衝吧！"
        case 30..<40:
            vibe = "30 多歲，事業與生活逐漸找到平衡，穩紮穩打的階段。"
        case 40..<50:
            vibe = "40 多歲，人生歷練豐富，是穩健前行的階段。"
        case 50..<60:
            vibe = "50 多歲，經驗與智慧兼具，值得被尊敬的階段。"
        case 60..<70:
            vibe = "60 多歲，是享受人生、傳承經驗的美好階段。"
        default:
            vibe = "人生的每個階段都值得好好珍惜！"
        }

        let genderNote = gender == "male"
            ? "身為一位穩重的\(genderLabel)，"
            : "身為一位活力十足的\(genderLabel)，"

        let addressNote = address.map { "（收件地址：\($0)）" } ?? ""

        return "\(name)，你好！你屬於「\(bracketLabel)」這個階層。\(genderNote)\(vibe)\(addressNote)"
    }
}
