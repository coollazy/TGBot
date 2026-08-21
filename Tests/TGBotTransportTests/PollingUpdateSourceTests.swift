import Testing
import Foundation
@testable import TGBotTransport

/// PollingUpdateSource 是上一輪從「fire-and-forget、立刻 return」修成「真的 block 住」
/// 的地方——這裡補上驗證：start() 真的會 block 到 stop() 被呼叫、offset 依已處理的
/// update_id 正確遞增、失敗時會退避重試但不會放棄。全程不碰真實網路，也不真的等待
/// 退避延遲（注入立即完成的 TimeProvider）。
@Suite("PollingUpdateSource")
struct PollingUpdateSourceTests {
    /// 讓退避邏輯裡的 sleep 立刻返回，測試才不用真的等好幾秒。
    struct InstantTimeProvider: TimeProvider {
        func now() -> Date { Date() }
        func sleep(for duration: TimeInterval) async throws {}
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }

        /// `value.append(...)` 是「讀出來、改、寫回去」三步，中間沒鎖住，兩個並發的
        /// writer 可能互相蓋掉對方那份（lost update）——這正是下面跨 chat 並發測試
        /// 會真的踩到的情境（修復前不會有並發 writer，用 get/set 就夠了）。mutate 把
        /// 整段讀改寫包在同一次 lock 裡，才是並發安全的寫法。
        func mutate(_ body: (inout T) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&_value)
        }
    }

    /// 依呼叫順序回傳預先寫好的結果（成功回一批 Update，或丟出錯誤模擬 getUpdates 失敗）。
    /// 用 actor（而非鎖）管理內部狀態：NSLock 的 lock()/unlock() 在 Swift 6 底下
    /// 不能直接在 async 函式裡呼叫（避免鎖跨越 suspension point），actor 是更正規的做法。
    actor ScriptedAPIClient: TelegramAPIClient {
        enum Step {
            case success([Update])
            case failure(Error)
        }
        private var steps: [Step]
        private(set) var receivedOffsets: [Int?] = []

        init(steps: [Step]) { self.steps = steps }

        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] {
            receivedOffsets.append(offset)
            guard !steps.isEmpty else {
                return [] // 腳本用完之後，安靜地回空陣列，不要讓迴圈一直丟錯誤
            }
            let step = steps.removeFirst()
            switch step {
            case .success(let updates): return updates
            case .failure(let error): throw error
            }
        }

        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {}
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
        func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {}
        func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws {}
        func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws {}
    }

    struct DummyError: Error {}

    /// 一次性開關：wait() 在 open() 被呼叫之前會一直掛著。用來讓某個 chat 的 handler
    /// 故意卡住，藉此驗證別的 chat 不會被拖累（如果真的還是序列化處理，下面兩個測試
    /// 會直接 deadlock/逾時，而不是斷言失敗——是更強的驗證方式）。
    actor Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("start(onUpdate:) blocks until stop() is called, then returns")
    func startBlocksUntilStopped() async throws {
        let apiClient = ScriptedAPIClient(steps: [
            .success([Update(updateID: 1, chatID: 1, text: "hi")])
        ])
        let source = PollingUpdateSource(apiClient: apiClient, clock: InstantTimeProvider())
        let received = Box<[Update]>([])

        // 如果 start() 沒有真的 block（回到上一輪修之前的行為），這個 await 會立刻
        // 返回，received 會是空的——這條測試就是專門守住那次修好的行為。
        try await source.start { update in
            received.value.append(update)
            await source.stop()
        }

        #expect(received.value.map(\.text) == ["hi"])
    }

    @Test("offset advances to the last processed update_id + 1 across successive calls")
    func offsetAdvancesAcrossCalls() async throws {
        let apiClient = ScriptedAPIClient(steps: [
            .success([Update(updateID: 5, chatID: 1, text: "a"), Update(updateID: 6, chatID: 1, text: "b")]),
            .success([Update(updateID: 9, chatID: 1, text: "c")]),
        ])
        let source = PollingUpdateSource(apiClient: apiClient, clock: InstantTimeProvider())
        let count = Box(0)

        try await source.start { _ in
            count.value += 1
            if count.value == 3 { await source.stop() }
        }

        // 第一次呼叫沒有 offset（nil，一開始還沒處理過任何東西）；
        // 第二次呼叫應該是「上一批最後一筆 update_id（6）+ 1」
        let offsets = await apiClient.receivedOffsets
        #expect(offsets[0] == nil)
        #expect(offsets[1] == 7)
    }

    @Test("a getUpdates failure triggers backoff but the loop keeps retrying instead of giving up")
    func failureTriggersRetryNotGiveUp() async throws {
        let apiClient = ScriptedAPIClient(steps: [
            .failure(DummyError()),
            .failure(DummyError()),
            .success([Update(updateID: 1, chatID: 1, text: "recovered")]),
        ])
        let source = PollingUpdateSource(apiClient: apiClient, clock: InstantTimeProvider())
        let received = Box<[Update]>([])

        try await source.start { update in
            received.value.append(update)
            await source.stop()
        }

        // 前兩次都失敗，第三次才成功；迴圈沒有因為失敗就放棄，最終還是拿到了那筆更新
        #expect(received.value.map(\.text) == ["recovered"])
        // 至少 3 次（兩次失敗 + 一次成功）；processedUpdate 現在是丟給獨立 Task 處理，
        // stop() 生效前輪詢迴圈可能已經又多跑了幾輪空的 getUpdates（步驟腳本跑完後
        // 安靜回傳空陣列）——這是這支測試用的 mock 沒有模擬真實 Telegram 長輪詢延遲
        // 才會出現的無害空轉，跟正確性無關，所以放寬成下限而非精確值。
        let offsetCount = await apiClient.receivedOffsets.count
        #expect(offsetCount >= 3)
    }

    @Test("different chats run concurrently: a stuck chat does not block another chat")
    func differentChatsRunConcurrently() async throws {
        let apiClient = ScriptedAPIClient(steps: [
            .success([
                Update(updateID: 1, chatID: 1, text: "slow"),
                Update(updateID: 2, chatID: 2, text: "fast"),
            ])
        ])
        let source = PollingUpdateSource(apiClient: apiClient, clock: InstantTimeProvider())
        let order = Box<[String]>([])
        let gate = Gate()

        // chat 1 的 handler 一開始就卡住，要等 chat 2 的 handler 開門才會繼續——
        // 如果兩個 chat 還是排隊處理（跟修復前一樣），chat 2 永遠輪不到，這個測試
        // 會直接卡住逾時，而不是斷言失敗，是比對斷言更直接的驗證。
        try await source.start { update in
            if update.chatID == 1 {
                order.mutate { $0.append("slow-start") }
                await gate.wait()
                order.mutate { $0.append("slow-end") }
                await source.stop()
            } else {
                order.mutate { $0.append("fast-start") }
                order.mutate { $0.append("fast-end") }
                await gate.open()
            }
        }

        // 「slow-start 是否比 fast-start 先被記錄」是良性的競爭（兩個不同 chat 各自
        // 獨立 spawn 的 Task，誰先真的開始執行本來就不保證、也不需要保證）；真正要
        // 驗證的並發保證是「fast chat 整個跑完（fast-start + fast-end）不需要等
        // slow chat 放開 gate」——slow-end 只會在 gate.open() 之後才追加，
        // gate.open() 又只會在 fast-end 之後才呼叫，所以只要 fast-end 出現在
        // slow-end 之前，就證明 fast chat 沒有被 slow chat 卡住。
        let finalOrder = order.value
        #expect(Set(finalOrder) == ["slow-start", "fast-start", "fast-end", "slow-end"])
        #expect(finalOrder.firstIndex(of: "fast-end")! < finalOrder.firstIndex(of: "slow-end")!)
    }

    @Test("the same chat still processes updates in strict arrival order even when earlier ones are slower")
    func sameChatStaysOrderedDespiteVaryingSpeed() async throws {
        let apiClient = ScriptedAPIClient(steps: [
            .success([
                Update(updateID: 1, chatID: 1, text: "one"),
                Update(updateID: 2, chatID: 1, text: "two"),
                Update(updateID: 3, chatID: 1, text: "three"),
            ])
        ])
        let source = PollingUpdateSource(apiClient: apiClient, clock: InstantTimeProvider())
        let order = Box<[String]>([])

        // 越早的 update 故意睡越久：如果同一個 chat 沒有嚴格鏈式排隊（只是各自並發跑），
        // 較晚、較快的 update 反而會先做完，斷言就會失敗，抓得到排序被打亂的迴歸。
        try await source.start { update in
            let delayMillis: UInt64 = update.text == "one" ? 30 : (update.text == "two" ? 15 : 0)
            try? await Task.sleep(nanoseconds: delayMillis * 1_000_000)
            var shouldStop = false
            order.mutate {
                $0.append(update.text ?? "")
                shouldStop = $0.count == 3
            }
            if shouldStop { await source.stop() }
        }

        #expect(order.value == ["one", "two", "three"])
    }
}
