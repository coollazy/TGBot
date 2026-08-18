import Foundation
import TGBot

/// 收集姓名／年齡／性別的多步驟對話流程範例，確認後依「性別 × 每 10 歲一個階層」
/// 回應不同的總結文字。示範：分支（依輸入是否合法決定 .stay 還是往下走）、
/// 用 inline 按鈕收集選項（callback_query 那條路徑）、多步驟 session 累積資料。
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
        let profile = makeProfileScene()
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
    static func makeProfileScene() -> Scene<ProfileState, ProfileData> {
        let scene = Scene<ProfileState, ProfileData>(name: "profile", initial: .askName, initialSession: ProfileData())

        scene.on(.askName) { ctx in
            // 這是流程的入口，ctx.text 此時是觸發指令本身（/profile），不是答案，忽略即可
            try await ctx.reply("你好！我們先來填一下資料。請問你的名字是？")
            return .transition(to: .askAge)
        }

        scene.on(.askAge) { ctx in
            // 上一步問的是名字，這裡收到的就是名字
            ctx.session.name = ctx.text
            try await ctx.reply("\(ctx.session.name ?? "你")幾歲呢？請輸入數字。")
            return .transition(to: .askGender)
        }

        scene.on(.askGender) { ctx in
            // 上一步問的是年齡；輸入不合法就留在原地重試（對應 US-2：錯誤發生時退回重試）
            guard let text = ctx.text, let age = Int(text), age >= 0, age <= 150 else {
                try await ctx.reply("這個年齡看起來怪怪的，請輸入一個 0～150 之間的數字。")
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

            try await ctx.reply(summaryText(name: name, age: age, gender: gender))
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
