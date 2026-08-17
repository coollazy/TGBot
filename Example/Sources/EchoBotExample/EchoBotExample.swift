import Foundation
import TGBot

/// 最小可運行範例：對機器人輸入 /echo 開始，之後傳的每一句話都會被原樣回覆。
/// 對應架構設計文件第 9 節「完整範例：從初始化到執行」。
///
/// 這是獨立於 TGBot library 本身的 SwiftPM 專案（見 ../Package.swift 用 local path
/// 依賴），只 `import TGBot` 這一個 module——刻意模擬真正外部開發者的使用情境。
///
/// 執行方式：
///   export TGBOT_TOKEN="你的 bot token（跟 @BotFather 申請）"
///   swift run
@main
struct EchoBotExample {
    enum EchoState: ConversationState {
        case listening
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

        // 一個最簡單的 scene：只有一個 state，收到什麼文字就回什麼文字。
        let echo = Scene<EchoState, EmptySession>(name: "echo", initial: .listening)
        echo.on(.listening) { ctx in
            try await ctx.reply("echo: \(ctx.text ?? "")")
            return .stay
        }
        bot.register(echo, trigger: .command("echo"))

        // 全域指令：取消目前流程（US-5），description 會自動同步進 Telegram 的指令選單。
        bot.onCommand("cancel", description: "取消目前進行中的流程") { ctx in
            await ctx.resetConversation()
            try await ctx.reply("已取消，若要重新開始請再次輸入 /echo。")
        }

        print("TGBot echo 範例已啟動，對機器人輸入 /echo 開始，之後傳的每一句話都會被原樣回覆。")
        try await bot.run()
    }
}
