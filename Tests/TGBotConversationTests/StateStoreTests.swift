import Testing
import Foundation
@testable import TGBotConversation

@Suite("InMemoryStateStore")
struct InMemoryStateStoreTests {
    @Test("load for a chatID that was never saved returns a fresh empty record (boundary: first contact)")
    func loadUnknownChatReturnsFreshRecord() async {
        let store = InMemoryStateStore()
        let record = await store.load(chatID: 999)
        #expect(record.activeScene == nil)
        #expect(record.currentStateData == nil)
    }

    @Test("save then load for the same chatID round-trips the record (inside)")
    func saveThenLoadRoundTrips() async {
        let store = InMemoryStateStore()
        var record = ChatConversationRecord()
        record.activeScene = "demo"
        record.sessionData = Data([1, 2, 3])
        await store.save(chatID: 1, record)

        let loaded = await store.load(chatID: 1)
        #expect(loaded.activeScene == "demo")
        #expect(loaded.sessionData == Data([1, 2, 3]))
    }

    @Test("records for different chatIDs are independent (outside: no cross-chat leakage)")
    func differentChatsAreIsolated() async {
        let store = InMemoryStateStore()
        var recordA = ChatConversationRecord()
        recordA.activeScene = "A"
        await store.save(chatID: 1, recordA)

        let untouched = await store.load(chatID: 2)
        #expect(untouched.activeScene == nil)
    }
}

@Suite("ChatConversationRecord.reset")
struct ChatConversationRecordResetTests {
    @Test("reset clears every conversation-flow field (inside)")
    func resetClearsConversationFields() {
        var record = ChatConversationRecord(
            activeScene: "demo",
            currentStateData: Data([9]),
            sessionData: Data([1, 2]),
            stateHistory: [Data([1])],
            sceneStack: []
        )
        record.reset()

        #expect(record.activeScene == nil)
        #expect(record.currentStateData == nil)
        #expect(record.sessionData == Data())
        #expect(record.stateHistory.isEmpty)
        #expect(record.sceneStack.isEmpty)
    }

    @Test("reset on an already-empty record is a safe no-op (boundary)")
    func resetOnEmptyRecordIsNoOp() {
        var record = ChatConversationRecord()
        record.reset()
        #expect(record.activeScene == nil)
        #expect(record.sessionData == Data())
    }
}
