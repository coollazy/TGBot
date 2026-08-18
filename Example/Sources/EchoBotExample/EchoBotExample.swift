import Foundation
import TGBot

/// 收集姓名／年齡／性別的多步驟對話流程範例，確認後依「性別 × 每 10 歲一個階層」
/// 回應不同的總結文字。示範：分支（依輸入是否合法決定 .stay 還是往下走）、
/// 用 inline 按鈕收集選項（callback_query 那條路徑）、多步驟 session 累積資料、
/// 流程中途插入一個長任務（確認後「產生總結」模擬成要跑 5 秒的背景任務，這段期間
/// bot 仍可正常回應其他訊息，任務完成後才送出總結、結束流程）、在被問年齡時輸入
/// 「上一步」可以體驗 Transition.rollback 真的退回上一步（重新輸入名字），不是原地不動、
/// 輸入「小提示」可以體驗 Transition.interrupt：暫停填資料的流程、岔去跑一個完全獨立的
/// 小提示子流程，子流程結束後自動接回原本填到一半、沒填完的地方繼續（不是重新開始）。
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

        // 小提示子流程：填 /profile 填到一半可以用「小提示」中斷進來，也能直接用
        // /tips 單獨啟動——中斷（Transition.interrupt）需要目標 scene 能被 registry
        // 查得到，所以這裡也要註冊，即使實務上通常是被中斷帶進來，不是使用者自己打指令進來的。
        // 建一次、兩邊共用同一個實例，不要各自各建一個同名但不同物件的 scene。
        let tips = makeTipsScene()
        bot.register(tips, trigger: .command("tips"), description: "查看這個範例的小提示")

        let profile = makeProfileScene(tipsScene: tips)
        bot.register(profile, trigger: .command("profile"), description: "開始填寫個人資料")

        // 全域指令：取消目前流程（US-5），description 會自動同步進 Telegram 的指令選單。
        bot.onCommand("cancel", description: "取消目前進行中的流程") { ctx in
            await ctx.resetConversation()
            try await ctx.reply("已取消，若要重新開始請再次輸入 /profile。")
        }

        print("TGBot profile 範例已啟動，對機器人輸入 /profile 開始填寫個人資料。")
        try await bot.run()
    }

    /// 每個 state 的 handler 處理的是「回答了什麼東西才進到這個 state」，
    /// 再問下一個問題、轉移到下一個 state——例如 .askAge 的 handler 收到的
    /// ctx.text 其實是使用者對「你叫什麼名字？」的回答（名字），不是年齡；
    /// 進到 .askAge 這個 state 本身才是要問年齡。
    static func makeProfileScene(tipsScene: Scene<TipsState, EmptySession>) -> Scene<ProfileState, ProfileData> {
        let scene = Scene<ProfileState, ProfileData>(name: "profile", initial: .askName, initialSession: ProfileData())

        scene.on(.askName) { ctx in
            // 這是流程的入口，ctx.text 此時是觸發指令本身（/profile），不是答案，忽略即可
            try await ctx.reply("你好！我們先來填一下資料。請問你的名字是？")
            return .transition(to: .askAge)
        }

        scene.on(.askAge) { ctx in
            // 上一步問的是名字，這裡收到的就是名字
            ctx.session.name = ctx.text
            try await ctx.reply("\(ctx.session.name ?? "你")幾歲呢？請輸入數字（也可以輸入「上一步」回去重新輸入名字、「小提示」查看提示）。")
            return .transition(to: .askGender)
        }

        scene.on(.askGender) { ctx in
            // 示範 US-2：Transition.rollback 現在真的會退回歷史棧記錄的「上一步」
            // （這裡是問名字、順便問年齡的那個 state），不是原地不動——輸入「上一步」
            // 就能重新輸入名字，年齡會用你重新輸入名字之後、下一次被問到時再填。
            if ctx.text == "上一步" {
                try await ctx.reply("好，我們重新來，請再輸入一次名字：")
                return .rollback
            }

            // 示範 US-1：Transition.interrupt 讓填資料的流程可以暫停自己、岔去跑一個
            // 完全獨立的子流程（小提示），跟填資料本身無關；子流程結束後會自動接回這裡
            // 繼續問年齡，不是重新開始整個 /profile。之前這裡直接 fatalError，完全沒實作。
            if ctx.text == "小提示" {
                return .interrupt(with: AnyScene(tipsScene))
            }

            // 上一步問的是年齡；輸入不合法就留在原地重試（對應 US-2：錯誤發生時退回重試）
            guard let text = ctx.text, let age = Int(text), age >= 0, age <= 150 else {
                try await ctx.reply("這個年齡看起來怪怪的，請輸入一個 0～150 之間的數字，或輸入「上一步」重新輸入名字、「小提示」查看提示。")
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

            try await ctx.replyWithMenu(
                """
                請確認以下資料：
                姓名：\(name)
                年齡：\(age)
                性別：\(genderLabel)
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
                    try await ctx.reply(summaryText(name: name, age: age, gender: gender))
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
            try await ctx.reply("好，我們繼續填資料：\(ctx.session.name ?? "你")幾歲呢？請輸入數字。")
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
            let tip: String
            switch ctx.callbackData {
            case "why":
                tip = "這是示範 Transition.interrupt：填資料填到一半也能先岔開處理別的事，" +
                    "處理完會自動接回原本沒填完的地方繼續，不用重新開始。"
            case "usage":
                tip = "這只是範例，不會真的把資料存到任何地方——bot 一重啟，資料就沒了。"
            default:
                tip = "請點選上面的按鈕。"
            }
            try await ctx.reply(tip)
            return .end
        }

        return scene
    }

    /// 依「性別 × 每 10 歲一個階層」產生不同的總結文字。
    static func summaryText(name: String, age: Int, gender: String) -> String {
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

        return "\(name)，你好！你屬於「\(bracketLabel)」這個階層。\(genderNote)\(vibe)"
    }
}
