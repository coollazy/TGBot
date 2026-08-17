import Testing
@testable import TGBotConversation

@Suite("Scene")
struct SceneTests {
    enum DemoState: ConversationState { case start }

    @Test("registering a handler on a let-bound Scene compiles and stores it")
    func registerHandler() async {
        let scene = Scene<DemoState, EmptySession>(name: "demo", initial: .start)
        scene.on(.start) { _ in .end }
        let handler = scene.handlers.handler(for: .start)
        #expect(handler != nil)
    }
}
