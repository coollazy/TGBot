import Testing
import Foundation
import Logging
import TGBotTransport
@testable import TGBotConversation

/// 驗證照片／檔案收發整條路徑：Update.photo/document 有正確傳到 ctx.photo/ctx.document
/// （AnyScene 建立 Context 那段），以及 ctx.replyWithPhoto/replyWithDocument/downloadFile
/// 有正確委派給 apiClient——跟 EchoBotEndToEndTests 同一套端對端手法，全程不碰真實網路。
@Suite("Photo/document context wiring")
struct PhotoDocumentContextTests {
    enum EchoState: ConversationState { case listening }

    final class RecordingAPIClient: TelegramAPIClient, @unchecked Sendable {
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
        // downloadFile(fileID:) 是 extension 語法糖（會透過 apiClient 存取，靜態綁定），
        // 只需要覆寫它實際依賴的兩個 requirement，鏈式呼叫就會正確打到這裡。
        func getFile(fileID: String) async throws -> String {
            "resolved/\(fileID)"
        }
        func downloadFile(filePath: String) async throws -> Data {
            "content-of-\(filePath)".data(using: .utf8)!
        }
    }

    /// scene handler 是 @Sendable 閉包，不能直接捕捉、修改一個區域 var（編譯器擋掉，
    /// 跟 RecordingAPIClient 需要是 class 是同一個理由）。用這個薄薄的 box 承接結果。
    final class Recorder: @unchecked Sendable {
        var document: IncomingFile?
        var photo: IncomingFile?
        var downloaded: Data?
    }

    struct NoOpScheduler: BackgroundTaskScheduling {
        func start(
            chatID: Int64, taskID: String,
            work: @escaping @Sendable (JobProgress) async throws -> Void,
            onComplete: @escaping @Sendable (JobResult) async throws -> Void
        ) async {}
        func status(chatID: Int64, taskID: String) async -> JobStatus? { nil }
    }

    private func makeEngine(apiClient: RecordingAPIClient) -> (ConversationEngine, EngineRegistry) {
        let registry = EngineRegistry()
        let engine = ConversationEngine(
            stateStore: InMemoryStateStore(),
            apiClient: apiClient,
            scheduler: NoOpScheduler(),
            logger: Logger(label: "test"),
            registry: registry
        )
        return (engine, registry)
    }

    @Test("an update carrying a document: ctx.document is populated, ctx.photo is nil (inside)")
    func documentUpdateReachesContext() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient: apiClient)

        let recorder = Recorder()
        let scene = Scene<EchoState, EmptySession>(name: "attach", initial: .listening)
        scene.on(.listening) { ctx in
            recorder.document = ctx.document
            recorder.photo = ctx.photo
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "attach")

        await engine.dispatch(update: Update(updateID: 1, chatID: 42, text: "/attach", commandName: "attach"))
        let document = IncomingFile(fileID: "doc-1", fileName: "report.pdf", mimeType: "application/pdf", fileSize: 99)
        await engine.dispatch(update: Update(updateID: 2, chatID: 42, document: document))

        #expect(recorder.document?.fileID == "doc-1")
        #expect(recorder.document?.fileName == "report.pdf")
        #expect(recorder.photo == nil)
    }

    @Test("ctx.replyWithPhoto/replyWithDocument delegate straight through to apiClient, caption included (inside)")
    func replySugarDelegatesToAPIClient() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient: apiClient)

        let scene = Scene<EchoState, EmptySession>(name: "attach-reply", initial: .listening)
        scene.on(.listening) { ctx in
            try await ctx.replyWithPhoto(.url("https://example.com/cat.png"), caption: "cute cat")
            try await ctx.replyWithDocument(.fileID("doc-abc"))
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "attach-reply")

        await engine.dispatch(update: Update(updateID: 1, chatID: 42, text: "/attach-reply", commandName: "attach-reply"))

        #expect(apiClient.sentPhotos.count == 1)
        #expect(apiClient.sentPhotos[0].chatID == 42)
        #expect(apiClient.sentPhotos[0].caption == "cute cat")
        if case .url(let value) = apiClient.sentPhotos[0].source {
            #expect(value == "https://example.com/cat.png")
        } else {
            Issue.record("expected .url source")
        }

        #expect(apiClient.sentDocuments.count == 1)
        #expect(apiClient.sentDocuments[0].caption == nil)
        if case .fileID(let value) = apiClient.sentDocuments[0].source {
            #expect(value == "doc-abc")
        } else {
            Issue.record("expected .fileID source")
        }
    }

    @Test("ctx.downloadFile(_:) chains getFile + downloadFile(filePath:) through the apiClient (inside)")
    func downloadFileChainsThroughAPIClient() async throws {
        let apiClient = RecordingAPIClient()
        let (engine, registry) = makeEngine(apiClient: apiClient)

        let recorder = Recorder()
        let scene = Scene<EchoState, EmptySession>(name: "download", initial: .listening)
        scene.on(.listening) { ctx in
            if let photo = ctx.photo {
                recorder.downloaded = try await ctx.downloadFile(photo)
            }
            return .stay
        }
        registry.registerScene(scene, commandTrigger: "download")

        await engine.dispatch(update: Update(updateID: 1, chatID: 42, text: "/download", commandName: "download"))
        let photo = IncomingFile(fileID: "photo-xyz", fileSize: 12345)
        await engine.dispatch(update: Update(updateID: 2, chatID: 42, photo: photo))

        #expect(recorder.downloaded == "content-of-resolved/photo-xyz".data(using: .utf8))
    }
}
