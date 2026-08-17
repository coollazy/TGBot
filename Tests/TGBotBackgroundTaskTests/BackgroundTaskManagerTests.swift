import Testing
import Foundation
import TGBotConversation
@testable import TGBotBackgroundTask

/// BackgroundTaskManager 是唯一的 v1 BackgroundTaskScheduling 實作，先前完全沒被測試過
/// ——測試裡一律用 NoOpScheduler 假貨代替。這裡直接測真正的 actor：work 成功／失敗
/// 兩條路徑、status() 在完成前後的狀態、不同 taskID 互不干擾。
///
/// start() 內部把工作丟進一個不被 await 的 Task，呼叫端立刻拿回控制權（這是刻意的，
/// 見架構設計文件第 7 節：啟動背景任務不能佔用呼叫端）。所以這裡用一個有上限次數的
/// 輪詢等待完成，而不是猜一個固定的 sleep 時間（避免測試在慢的 CI 環境上偶發失敗）。
@Suite("BackgroundTaskManager")
struct BackgroundTaskManagerTests {
    struct DummyError: Error {}

    func waitUntil(maxAttempts: Int = 200, _ condition: () async -> Bool) async {
        for _ in 0..<maxAttempts {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms，累計上限 200ms
        }
    }

    @Test("a successful work closure reports .success to onComplete and status becomes finished (inside)")
    func successPath() async {
        let manager = BackgroundTaskManager()
        actor Result { var value: JobResult?; func set(_ r: JobResult) { value = r } }
        let result = Result()

        await manager.start(chatID: 1, taskID: "job-1", work: { progress in
            await progress.update("working")
        }, onComplete: { r in
            await result.set(r)
        })

        await waitUntil { await result.value != nil }
        let finalStatus = await manager.status(chatID: 1, taskID: "job-1")

        if case .success = await result.value { /* ok */ } else {
            Issue.record("expected .success")
        }
        #expect(finalStatus?.isFinished == true)
        #expect(finalStatus?.lastMessage == "working")
    }

    @Test("a throwing work closure reports .failure to onComplete instead of crashing or hanging (outside)")
    func failurePath() async {
        let manager = BackgroundTaskManager()
        actor Result { var value: JobResult?; func set(_ r: JobResult) { value = r } }
        let result = Result()

        await manager.start(chatID: 1, taskID: "job-2", work: { _ in
            throw DummyError()
        }, onComplete: { r in
            await result.set(r)
        })

        await waitUntil { await result.value != nil }

        if case .failure = await result.value { /* ok */ } else {
            Issue.record("expected .failure")
        }
        let finalStatus = await manager.status(chatID: 1, taskID: "job-2")
        #expect(finalStatus?.isFinished == true)
    }

    @Test("status() before the job finishes reports isFinished == false (boundary: in-flight)")
    func statusBeforeFinished() async {
        let manager = BackgroundTaskManager()
        let canFinish = AsyncBarrier()

        await manager.start(chatID: 1, taskID: "job-3", work: { _ in
            await canFinish.wait() // 卡住，直到測試主動放行
        }, onComplete: { _ in })

        let inFlightStatus = await manager.status(chatID: 1, taskID: "job-3")
        #expect(inFlightStatus?.isFinished == false)

        await canFinish.release()
    }

    @Test("status() for a taskID that was never started returns nil (boundary: unknown key)")
    func statusForUnknownTaskIsNil() async {
        let manager = BackgroundTaskManager()
        let status = await manager.status(chatID: 1, taskID: "never-started")
        #expect(status == nil)
    }

    @Test("two different taskIDs under the same chat are tracked independently (outside: no cross-task leakage)")
    func differentTaskIDsAreIsolated() async {
        let manager = BackgroundTaskManager()
        await manager.start(chatID: 1, taskID: "job-a", work: { progress in
            await progress.update("A")
        }, onComplete: { _ in })
        await manager.start(chatID: 1, taskID: "job-b", work: { progress in
            await progress.update("B")
        }, onComplete: { _ in })

        await waitUntil {
            let a = await manager.status(chatID: 1, taskID: "job-a")
            let b = await manager.status(chatID: 1, taskID: "job-b")
            return a?.isFinished == true && b?.isFinished == true
        }

        let statusA = await manager.status(chatID: 1, taskID: "job-a")
        let statusB = await manager.status(chatID: 1, taskID: "job-b")
        #expect(statusA?.lastMessage == "A")
        #expect(statusB?.lastMessage == "B")
    }
}

/// 讓一個背景工作卡住、直到測試主動放行，用來驗證「還沒完成時」的狀態，
/// 不用猜測時間。
actor AsyncBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
