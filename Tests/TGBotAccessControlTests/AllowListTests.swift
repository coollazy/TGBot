import Testing
@testable import TGBotAccessControl

/// AllowList 是安全相關的白名單邏輯（見架構設計文件第 5 節）：
/// 未設定＝opt-in 公開模式；userIDs／chatIDs 任一非空即轉私人模式。
/// 每個分支各給 inside（該擋的擋住／該放行的放行）、outside（不該符合的不要誤放行）、
/// 邊界（兩個集合恰好都空、userID 為 nil）三種案例。
@Suite("AllowList")
struct AllowListTests {
    @Test("both empty = public mode: everyone allowed (boundary case)")
    func emptyMeansPublic() {
        let list = AllowList()
        #expect(list.isAllowed(userID: 999, chatID: 999))
        #expect(list.isAllowed(userID: nil, chatID: 999))
    }

    @Test("only userIDs set: matching userID allowed (inside)")
    func userIDInsideAllowList() {
        let list = AllowList(userIDs: [111])
        #expect(list.isAllowed(userID: 111, chatID: 42))
    }

    @Test("only userIDs set: non-matching userID rejected, even with unrelated chatID (outside)")
    func userIDOutsideAllowList() {
        let list = AllowList(userIDs: [111])
        #expect(!list.isAllowed(userID: 222, chatID: 42))
    }

    @Test("only userIDs set: nil userID (e.g. channel post) is rejected, not silently allowed (boundary)")
    func nilUserIDWithUserIDOnlyList() {
        let list = AllowList(userIDs: [111])
        #expect(!list.isAllowed(userID: nil, chatID: 42))
    }

    @Test("only chatIDs set: matching chatID allowed (inside)")
    func chatIDInsideAllowList() {
        let list = AllowList(chatIDs: [42])
        #expect(list.isAllowed(userID: 999, chatID: 42))
    }

    @Test("only chatIDs set: non-matching chatID rejected (outside)")
    func chatIDOutsideAllowList() {
        let list = AllowList(chatIDs: [42])
        #expect(!list.isAllowed(userID: 999, chatID: 7))
    }

    @Test("both set: userID match short-circuits even if chatID doesn't match (inside)")
    func eitherListMatchingIsSufficient() {
        let list = AllowList(userIDs: [111], chatIDs: [42])
        #expect(list.isAllowed(userID: 111, chatID: 999))
        #expect(list.isAllowed(userID: 999, chatID: 42))
    }

    @Test("both set: neither matches, rejected (outside)")
    func bothSetNeitherMatches() {
        let list = AllowList(userIDs: [111], chatIDs: [42])
        #expect(!list.isAllowed(userID: 222, chatID: 7))
    }
}
