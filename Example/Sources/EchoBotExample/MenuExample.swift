import Foundation
import TGBot

/// 主選單／註冊／建立活動／設定——比 `/profile` 複雜得多的多層 Scene 範例，目的不是
/// 「示範一個功能」，是拿來當壓力測試，逼出 `onEnter`（見 Scene.swift）跟
/// `AnyScene(_:initialSession:)`（見 AnyScene.swift）這兩個機制在真實情境下好不好用：
///
/// - **主選單 → 註冊**：`.interrupt(with:onReturn:)`，確認才把資料帶回主選單、取消不帶回。
///   `onReturn` 回傳 `.transition(to: .menu)`（不是 `.stay`）讓 `onEnter(.menu)` 自動
///   重新顯示選單，不用在 onReturn 裡手動回話。
/// - **註冊 Scene 本身**：每個欄位都是 `onEnter`（顯示這一題的提示/選單）跟 `on`
///   （驗證這一題的答案、決定轉移到哪）乾淨拆開的示範——對照 `EchoBotExample.swift`
///   的 `/profile`（`.askAge` 的 handler 卻在處理上一題「名字」的答案）刻意做對比。
/// - **主選單 → 建立活動**：背景任務進度用「使用者主動問才回答」（`ctx.backgroundJobStatus`），
///   不是框架目前不支援的主動推播；完成後選單可以循環（繼續建立）或帶著這次建立的所有
///   活動一次結束（返回主選單）。
/// - **主選單 → 設定 → 顯示註冊資訊／顯示所有活動**：兩層巢狀 `.interrupt`，設定用
///   `AnyScene(_:initialSession:)` 從主選單帶著現有資料進去（不然中斷帶進去的子流程
///   永遠是全新空的 session，設定要顯示的東西根本看不到），設定自己再往下一層一樣用
///   `initialSession` 傳下去。這三個都是純唯讀查詢，不用 `onReturn`，用 `onResume`
///   接住從子流程回來的那一刻重新顯示選單。
///
/// 跟 `/profile` 完全獨立、互不影響，用 `/menu` 觸發。
enum MenuExample {
    struct Event: Codable, Sendable {
        var name: String
    }

    struct RegisteredProfile: Codable, Sendable {
        var name: String
        var age: Int
        var gender: String // "male" / "female"
    }

    // MARK: - 主選單

    enum MainMenuState: ConversationState {
        case menu
    }

    struct MainMenuSession: Codable, Sendable {
        var profile: RegisteredProfile?
        var events: [Event] = []
    }

    static func makeMainMenuScene(
        registerScene: Scene<RegisterState, RegisterSession>,
        createEventScene: Scene<CreateEventState, CreateEventSession>,
        settingsScene: Scene<SettingsState, SettingsSession>
    ) -> Scene<MainMenuState, MainMenuSession> {
        let scene = Scene<MainMenuState, MainMenuSession>(name: "menu-main", initial: .menu, initialSession: MainMenuSession())

        @Sendable func sendMenu(_ ctx: Context<MainMenuState, MainMenuSession>) async throws {
            try await ctx.replyWithMenu(
                "請選擇要做什麼：",
                buttons: [[
                    InlineButton(text: "註冊", callbackData: "register"),
                    InlineButton(text: "建立活動", callbackData: "create_event"),
                    InlineButton(text: "設定", callbackData: "settings"),
                ]]
            )
        }

        // 轉移進場（bootstrap／從註冊或建立活動的 onReturn 轉回 .menu）都會自動觸發，
        // 顯示選單不用散落在每個觸發點自己回話。
        scene.onEnter(.menu) { ctx in
            try await sendMenu(ctx)
            return .stay
        }

        // 從「設定」（純唯讀，沒有 onReturn）回來時，onEnter 不會觸發（那是恢復被中斷
        // 流程的路徑，跟「轉移進場」是兩件事），靠 onResume 重新顯示選單。
        scene.onResume(.menu) { ctx in
            try await sendMenu(ctx)
        }

        scene.on(.menu) { ctx in
            switch ctx.callbackData {
            case "register":
                return .interrupt(with: AnyScene(registerScene)) { (profile: RegisteredProfile, ctx: Context<MainMenuState, MainMenuSession>) in
                    ctx.session.profile = profile
                    return .transition(to: .menu)
                }
            case "create_event":
                return .interrupt(with: AnyScene(createEventScene)) { (events: [Event], ctx: Context<MainMenuState, MainMenuSession>) in
                    ctx.session.events.append(contentsOf: events)
                    return .transition(to: .menu)
                }
            case "settings":
                // 純唯讀查詢，不需要子流程回傳任何東西，但需要把現有資料「帶進去」——
                // 這就是 AnyScene(_:initialSession:) 存在的理由。
                return .interrupt(with: AnyScene(
                    settingsScene,
                    initialSession: SettingsSession(profile: ctx.session.profile, events: ctx.session.events)
                ))
            default:
                try await ctx.reply("請點選上面的按鈕。")
                return .stay
            }
        }

        return scene
    }

    // MARK: - 註冊

    enum RegisterState: ConversationState {
        case askName, askAge, askGender, confirm
    }

    struct RegisterSession: Codable, Sendable {
        var name: String?
        var age: Int?
        var gender: String?
    }

    /// `helpScene`：純說明用的唯讀子流程，用來在 `.askGender` 示範中斷＋恢復＋rollback
    /// 三者疊在一起的情境——填到性別這步可以打「小提示」岔出去看說明，回來後再打
    /// 「上一步」，驗證中斷前累積的歷史（姓名、年齡兩步）真的還在，不是被中斷這件事
    /// 本身清空了。
    static func makeRegisterScene(helpScene: Scene<RegisterHelpState, EmptySession>) -> Scene<RegisterState, RegisterSession> {
        let scene = Scene<RegisterState, RegisterSession>(name: "menu-register", initial: .askName, initialSession: RegisterSession())

        scene.onEnter(.askName) { ctx in
            try await ctx.reply("請輸入姓名（純中英文，不能有符號或數字）：")
            return .stay
        }
        scene.on(.askName) { ctx in
            guard let text = ctx.text, !text.isEmpty, text.allSatisfy({ $0.isLetter }) else {
                try await ctx.reply("姓名只能是純中英文字，不能有符號或數字，請重新輸入：")
                return .stay
            }
            ctx.session.name = text
            return .transition(to: .askAge)
        }

        scene.onEnter(.askAge) { ctx in
            try await ctx.reply("請輸入年齡（1～100 的數字）：")
            return .stay
        }
        scene.on(.askAge) { ctx in
            guard let text = ctx.text, let age = Int(text), (1...100).contains(age) else {
                try await ctx.reply("年齡請輸入 1～100 之間的數字，請重新輸入：")
                return .stay
            }
            ctx.session.age = age
            return .transition(to: .askGender)
        }

        // 「上一步」「小提示」都做成按鈕，不用打字——跟男/女選項放在同一則訊息，
        // 分開兩排比較好按。
        let askGenderButtons: [[InlineButton]] = [
            [
                InlineButton(text: "男", callbackData: "male"),
                InlineButton(text: "女", callbackData: "female"),
            ],
            [
                InlineButton(text: "上一步", callbackData: "back"),
                InlineButton(text: "小提示", callbackData: "help"),
            ],
        ]

        scene.onEnter(.askGender) { ctx in
            try await ctx.replyWithMenu("請選擇性別：", buttons: askGenderButtons)
            return .stay
        }
        scene.on(.askGender) { ctx in
            // 示範 #4 的修復：填到這一步時，姓名／年齡兩題的歷史已經累積了兩筆。
            // 「小提示」中斷去跑一個純說明的子流程，回來後「上一步」應該還是能正確
            // 退回「填年齡」——不會因為中間岔出去過，歷史就被清空、退不回去。
            switch ctx.callbackData {
            case "back":
                try await ctx.reply("好，我們重新來，請再輸入一次年齡：")
                return .rollback
            case "help":
                return .interrupt(with: AnyScene(helpScene))
            case "male", "female":
                ctx.session.gender = ctx.callbackData
                return .transition(to: .confirm)
            default:
                try await ctx.reply("請點選上面的按鈕。")
                return .stay
            }
        }
        // 純中斷、沒有 onReturn（小提示不需要交回任何資料），恢復要靠 onResume 主動
        // 重新交代現在在等什麼，不然使用者岔出去看完說明回來，會不知道要幹嘛。
        scene.onResume(.askGender) { ctx in
            try await ctx.replyWithMenu("好，我們繼續：請選擇性別：", buttons: askGenderButtons)
        }

        scene.onEnter(.confirm) { ctx in
            let genderLabel = ctx.session.gender == "male" ? "男" : "女"
            try await ctx.replyWithMenu(
                """
                請確認以下資料：
                姓名：\(ctx.session.name ?? "")
                年齡：\(ctx.session.age.map(String.init) ?? "")
                性別：\(genderLabel)
                """,
                buttons: [[
                    InlineButton(text: "確認", callbackData: "confirm"),
                    InlineButton(text: "取消", callbackData: "cancel"),
                ]]
            )
            return .stay
        }
        scene.on(.confirm) { ctx in
            switch ctx.callbackData {
            case "confirm":
                guard let name = ctx.session.name, let age = ctx.session.age, let gender = ctx.session.gender else {
                    return .end
                }
                // 確認才帶結果出去——.end(with:) 會被主選單的 onReturn 接住。
                return try .end(with: RegisteredProfile(name: name, age: age, gender: gender))
            case "cancel":
                // 沒帶結果的舊版 .end：主選單的 onReturn 不會被呼叫，profile 維持原樣不動。
                return .end
            default:
                try await ctx.reply("請點選上面的按鈕。")
                return .stay
            }
        }

        return scene
    }

    // MARK: - 註冊：小提示（純說明用的中斷子流程）

    enum RegisterHelpState: ConversationState {
        case display
    }

    /// 完全獨立、不需要任何資料，純粹展示「中斷去跑一個子流程、看完說明、自動接回
    /// 原本的流程」——不帶結果回去（沒有 onReturn），恢復要靠 `onResume`。
    static func makeRegisterHelpScene() -> Scene<RegisterHelpState, EmptySession> {
        let scene = Scene<RegisterHelpState, EmptySession>(name: "menu-register-help", initial: .display)

        scene.onEnter(.display) { ctx in
            try await ctx.reply("我們只用這些資料示範多步驟表單，不會真的存到任何地方，bot 一重啟就沒了。")
            return .end
        }

        return scene
    }

    // MARK: - 建立活動

    enum CreateEventState: ConversationState {
        case askName, creating, afterCreate
    }

    struct CreateEventSession: Codable, Sendable {
        var pendingName: String?
        // 這次進場（可能透過「繼續建立」循環好幾次）累積建立的所有活動，
        // 最後「返回主選單」時一次帶回去，不是每建一個就各自回傳一次。
        var createdEvents: [Event] = []
    }

    static func makeCreateEventScene() -> Scene<CreateEventState, CreateEventSession> {
        let scene = Scene<CreateEventState, CreateEventSession>(name: "menu-create-event", initial: .askName, initialSession: CreateEventSession())

        scene.onEnter(.askName) { ctx in
            try await ctx.reply("請輸入活動名稱：")
            return .stay
        }
        scene.on(.askName) { ctx in
            guard let text = ctx.text, !text.isEmpty else {
                try await ctx.reply("活動名稱不能是空的，請重新輸入：")
                return .stay
            }
            ctx.session.pendingName = text
            return .transition(to: .creating)
        }

        scene.onEnter(.creating) { ctx in
            try await ctx.reply("活動建立中，請稍候（約 10 秒）——這段期間可以跟我說話問進度，不會被卡住。")
            let name = ctx.session.pendingName ?? "未命名活動"
            ctx.startBackgroundJob(id: "create-event", work: { progress in
                // 已知限制：這裡沒有管道能主動推播訊息給使用者（work 閉包只拿得到
                // JobProgress，不是完整的 Context），所以「還要等幾秒」只能被動更新
                // 一個可查詢的狀態字串，不能每秒自己跳出來講話——這是使用者跟我確認過
                // 要接受的範圍，見 README「已知限制」。
                // 先回報進度、再 sleep——JobStatus.lastMessage 初始值是空字串，如果
                // 顛倒順序（sleep 完才 update），任務剛開始的頭 1 秒內使用者主動問進度
                // 會拿到空字串，ctx.reply("") 被 Telegram 直接拒收（400 Bad Request:
                // message text is empty），看起來就像完全沒回話——這是實機測試才踩到的坑。
                for remaining in stride(from: 10, through: 1, by: -1) {
                    await progress.update("還要等 \(remaining) 秒")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }, onComplete: { result, taskID, ctx in
                switch result {
                case .success:
                    ctx.session.createdEvents.append(Event(name: name))
                    try await ctx.replyWithMenu(
                        "活動「\(name)」建立完成！",
                        buttons: [[
                            InlineButton(text: "繼續建立", callbackData: "continue_create"),
                            InlineButton(text: "返回主選單", callbackData: "back_to_main"),
                        ]]
                    )
                case .failure:
                    try await ctx.reply("活動建立失敗，請重新輸入活動名稱：")
                    return .transition(to: .askName)
                }
                // 已知限制：這個 transition 是背景任務完成時觸發的
                // （ConversationEngine.applyBackgroundTransition），這條路徑沒有接上
                // onEnter（這次補 onEnter 時刻意沒涵蓋的第三個觸發點）——所以上面選單
                // 是在這裡直接回話，不是靠 .afterCreate 的 onEnter 自動顯示。
                return .transition(to: .afterCreate)
            })
            return .stay
        }
        scene.on(.creating) { ctx in
            // 使用者這時候傳來的任何話都當作在問進度——主動查詢，不是被動等推播。
            // 保底：萬一真的在極早期（work 閉包第一次 progress.update 之前）問進度，
            // lastMessage 還是空字串，不要把空字串直接送出去（Telegram 會拒收）。
            let reply: String
            if let status = await ctx.backgroundJobStatus(id: "create-event") {
                if status.isFinished {
                    reply = "已經完成了，通知馬上就到。"
                } else if status.lastMessage.isEmpty {
                    // 極早期：work 閉包還沒來得及第一次 progress.update() 就被問到。
                    reply = "建立中，請稍候。"
                } else {
                    reply = status.lastMessage
                }
            } else {
                reply = "建立中，請稍候。"
            }
            try await ctx.reply(reply)
            return .stay
        }

        scene.on(.afterCreate) { ctx in
            switch ctx.callbackData {
            case "continue_create":
                return .transition(to: .askName)
            case "back_to_main":
                return try .end(with: ctx.session.createdEvents)
            default:
                try await ctx.reply("請點選上面的按鈕。")
                return .stay
            }
        }

        return scene
    }

    // MARK: - 設定

    enum SettingsState: ConversationState {
        case menu
    }

    struct SettingsSession: Codable, Sendable {
        var profile: RegisteredProfile?
        var events: [Event]
    }

    static func makeSettingsScene(
        showProfileScene: Scene<ShowProfileState, ShowProfileSession>,
        showEventsScene: Scene<ShowEventsState, ShowEventsSession>
    ) -> Scene<SettingsState, SettingsSession> {
        let scene = Scene<SettingsState, SettingsSession>(
            name: "menu-settings",
            initial: .menu,
            initialSession: SettingsSession(profile: nil, events: [])
        )

        @Sendable func sendMenu(_ ctx: Context<SettingsState, SettingsSession>) async throws {
            try await ctx.replyWithMenu(
                "設定：",
                buttons: [
                    [
                        InlineButton(text: "顯示註冊資訊", callbackData: "show_profile"),
                        InlineButton(text: "顯示所有活動", callbackData: "show_events"),
                    ],
                    [InlineButton(text: "返回主選單", callbackData: "back_to_main")],
                ]
            )
        }

        scene.onEnter(.menu) { ctx in
            try await sendMenu(ctx)
            return .stay
        }
        scene.onResume(.menu) { ctx in
            try await sendMenu(ctx)
        }

        scene.on(.menu) { ctx in
            switch ctx.callbackData {
            case "show_profile":
                return .interrupt(with: AnyScene(
                    showProfileScene,
                    initialSession: ShowProfileSession(profile: ctx.session.profile)
                ))
            case "show_events":
                return .interrupt(with: AnyScene(
                    showEventsScene,
                    initialSession: ShowEventsSession(events: ctx.session.events, ascending: true)
                ))
            case "back_to_main":
                return .end
            default:
                try await ctx.reply("請點選上面的按鈕。")
                return .stay
            }
        }

        return scene
    }

    // MARK: - 顯示註冊資訊

    enum ShowProfileState: ConversationState {
        case menu, showName, showAge, showGender
    }

    struct ShowProfileSession: Codable, Sendable {
        var profile: RegisteredProfile?
    }

    static func makeShowProfileScene() -> Scene<ShowProfileState, ShowProfileSession> {
        let scene = Scene<ShowProfileState, ShowProfileSession>(
            name: "menu-show-profile",
            initial: .menu,
            initialSession: ShowProfileSession(profile: nil)
        )

        // 再一層選單：使用者自己選要看姓名、年齡還是性別，不是三個一次全部印出來。
        scene.onEnter(.menu) { ctx in
            try await ctx.replyWithMenu(
                "想看哪一項？",
                buttons: [
                    [
                        InlineButton(text: "姓名", callbackData: "name"),
                        InlineButton(text: "年齡", callbackData: "age"),
                        InlineButton(text: "性別", callbackData: "gender"),
                    ],
                    [InlineButton(text: "返回設定", callbackData: "back")],
                ]
            )
            return .stay
        }
        scene.on(.menu) { ctx in
            switch ctx.callbackData {
            case "name": return .transition(to: .showName)
            case "age": return .transition(to: .showAge)
            case "gender": return .transition(to: .showGender)
            case "back": return .end
            default:
                try await ctx.reply("請點選上面的按鈕。")
                return .stay
            }
        }

        scene.onEnter(.showName) { ctx in
            let text = ctx.session.profile.map { "姓名：\($0.name)" } ?? "尚未註冊。"
            try await ctx.replyWithMenu(text, buttons: [[InlineButton(text: "返回", callbackData: "back")]])
            return .stay
        }
        scene.onEnter(.showAge) { ctx in
            let text = ctx.session.profile.map { "年齡：\($0.age)" } ?? "尚未註冊。"
            try await ctx.replyWithMenu(text, buttons: [[InlineButton(text: "返回", callbackData: "back")]])
            return .stay
        }
        scene.onEnter(.showGender) { ctx in
            let text = ctx.session.profile.map { "性別：\($0.gender == "male" ? "男" : "女")" } ?? "尚未註冊。"
            try await ctx.replyWithMenu(text, buttons: [[InlineButton(text: "返回", callbackData: "back")]])
            return .stay
        }
        // 三個顯示 state 都用同一招：轉移回 .menu，讓 onEnter(.menu) 自動重新顯示選單，
        // 不用各自手動回話一次。
        let backToMenu: @Sendable (Context<ShowProfileState, ShowProfileSession>) async throws -> Transition<ShowProfileState> = { _ in
            .transition(to: .menu)
        }
        scene.on(.showName, handler: backToMenu)
        scene.on(.showAge, handler: backToMenu)
        scene.on(.showGender, handler: backToMenu)

        return scene
    }

    // MARK: - 顯示所有活動

    enum ShowEventsState: ConversationState {
        case display
    }

    struct ShowEventsSession: Codable, Sendable {
        var events: [Event]
        var ascending: Bool
    }

    static func makeShowEventsScene() -> Scene<ShowEventsState, ShowEventsSession> {
        let scene = Scene<ShowEventsState, ShowEventsSession>(
            name: "menu-show-events",
            initial: .display,
            initialSession: ShowEventsSession(events: [], ascending: true)
        )

        scene.onEnter(.display) { ctx in
            let ordered = ctx.session.ascending ? ctx.session.events : Array(ctx.session.events.reversed())
            let list = ordered.isEmpty
                ? "目前還沒有建立任何活動。"
                : ordered.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n")
            try await ctx.replyWithMenu(
                "\(ctx.session.ascending ? "正序" : "逆序")顯示活動：\n\(list)",
                buttons: [[
                    InlineButton(text: ctx.session.ascending ? "改成逆序" : "改成正序", callbackData: "toggle"),
                    InlineButton(text: "返回", callbackData: "back"),
                ]]
            )
            return .stay
        }
        scene.on(.display) { ctx in
            switch ctx.callbackData {
            case "toggle":
                // 轉移到「自己」逼 onEnter 重新渲染，不用在這裡手動重新回話一次。
                ctx.session.ascending.toggle()
                return .transition(to: .display)
            case "back":
                return .end
            default:
                try await ctx.reply("請點選上面的按鈕。")
                return .stay
            }
        }

        return scene
    }
}
