import Testing
import Foundation
import Logging
import TGBot
@testable import EchoBotExample

/// 示範「外部開發者怎麼幫自己的 bot 寫離線單元測試」：完全不連真實的 Telegram，
/// 用假的 TelegramAPIClient／BackgroundTaskScheduling 取代，直接呼叫
/// ConversationEngine.dispatch(update:) 餵一筆手動建的 Update 進去，斷言假 apiClient
/// 收到了什麼。測的是 EchoBotExample.swift 裡真正的 makeUploadScene()（/upload 指令），
/// 不是另外掰一個玩具範例——跟 TGBot library 自己 129 個測試同一套寫法，差別只在
/// 這裡是「外部開發者視角」：只 import TGBot，不需要碰 TGBot 內部任何一個 module。
///
/// @testable 這裡是測自己專案的 EchoBotExample（executable target 預設 internal，
/// 跨 target 測試需要），跟 import TGBot 那條路徑（TGBot 自己 public API）是兩件事，
/// 不要混淆。
@Suite("EchoBotExample /upload scene")
struct UploadSceneTests {
    final class FakeAPIClient: TelegramAPIClient, @unchecked Sendable {
        private(set) var sentMessages: [(chatID: Int64, text: String)] = []
        private(set) var sentPhotos: [(chatID: Int64, source: TGFileSource, caption: String?)] = []
        private(set) var sentDocuments: [(chatID: Int64, source: TGFileSource, caption: String?)] = []

        func sendMessage(chatID: Int64, text: String, inlineKeyboard: [[TGInlineKeyboardButton]]?) async throws {
            sentMessages.append((chatID, text))
        }
        func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] { [] }
        func setMyCommands(_ commands: [(name: String, description: String)]) async throws {}
        func answerCallbackQuery(callbackQueryID: String, text: String?) async throws {}
        func editMessageReplyMarkup(chatID: Int64, messageID: Int64) async throws {}
        func editMessageText(chatID: Int64, messageID: Int64, text: String) async throws {}

        func sendPhoto(chatID: Int64, photo: TGFileSource, caption: String?) async throws {
            sentPhotos.append((chatID, photo, caption))
        }
        func sendDocument(chatID: Int64, document: TGFileSource, caption: String?) async throws {
            sentDocuments.append((chatID, document, caption))
        }
        // downloadFile(fileID:) 是 TelegramAPIClient 的 extension 語法糖（透過 apiClient
        // 呼叫時靜態綁定），實際依賴的是這兩個 requirement，覆寫這兩個就夠了。
        func getFile(fileID: String) async throws -> String { "resolved/\(fileID)" }
        func downloadFile(filePath: String) async throws -> Data { "bytes-of-\(filePath)".data(using: .utf8)! }
    }

    struct NoOpScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
    }

    private func makeEngine() -> (ConversationEngine, EngineRegistry, FakeAPIClient) {
        let apiClient = FakeAPIClient()
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )
        registry.registerScene(EchoBotExample.makeUploadScene(), commandTrigger: "upload")
        return (engine, registry, apiClient)
    }

    @Test("/upload 之後沒附件：留在原地提醒使用者，不會誤判成完成")
    func noAttachmentStaysAndPrompts() async throws {
        let (engine, _, apiClient) = makeEngine()

        await engine.dispatch(update: Update(chatID: 1, text: "/upload", commandName: "upload"))
        await engine.dispatch(update: Update(chatID: 1, text: "隨便說點什麼"))

        #expect(apiClient.sentMessages.count == 2)
        #expect(apiClient.sentPhotos.isEmpty)
        #expect(apiClient.sentDocuments.isEmpty)
    }

    @Test("傳照片：用同一個 file_id 原樣轉發回去，不用重新上傳")
    func photoIsForwardedByFileID() async throws {
        let (engine, _, apiClient) = makeEngine()

        await engine.dispatch(update: Update(chatID: 1, text: "/upload", commandName: "upload"))
        let photo = IncomingFile(fileID: "photo-abc", fileSize: 1234)
        await engine.dispatch(update: Update(chatID: 1, photo: photo))

        #expect(apiClient.sentPhotos.count == 1)
        if case .fileID(let value) = apiClient.sentPhotos[0].source {
            #expect(value == "photo-abc")
        } else {
            Issue.record("expected .fileID source")
        }
    }

    @Test("傳檔案：真的下載內容，並用同一個 file_id 轉發回去")
    func documentIsDownloadedAndForwarded() async throws {
        let (engine, _, apiClient) = makeEngine()

        await engine.dispatch(update: Update(chatID: 1, text: "/upload", commandName: "upload"))
        let document = IncomingFile(fileID: "doc-abc", fileName: "notes.txt", mimeType: "text/plain", fileSize: 42)
        await engine.dispatch(update: Update(chatID: 1, document: document))

        #expect(apiClient.sentMessages.last?.text.contains("notes.txt") == true)
        #expect(apiClient.sentDocuments.count == 1)
        if case .fileID(let value) = apiClient.sentDocuments[0].source {
            #expect(value == "doc-abc")
        } else {
            Issue.record("expected .fileID source")
        }
    }
}
