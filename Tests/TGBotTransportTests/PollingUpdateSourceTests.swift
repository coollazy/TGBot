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
    }

    struct DummyError: Error {}

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
        let offsetCount = await apiClient.receivedOffsets.count
        #expect(offsetCount == 3)
    }
}
