#if os(macOS)
import XCTest
@testable import Rubien

final class AssistantSessionAttributionStoreTests: XCTestCase {
    func testRecordsAliasesFiltersHomeAndPersistsWithoutSessionIDs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-attribution-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("index.json")
        let workspace = URL(fileURLWithPath: "/tmp/rubien-workspace", isDirectory: true)
        let conversation = UUID()
        let store = AssistantSessionAttributionStore(fileURL: file)

        await store.record(
            sessionID: "home-session-1",
            provider: .claude,
            workspaceURL: workspace,
            conversationId: conversation,
            context: .library)
        await store.record(
            sessionID: "home-session-rotated",
            provider: .claude,
            workspaceURL: workspace,
            conversationId: conversation,
            context: .library)
        await store.record(
            sessionID: "reader-session",
            provider: .claude,
            workspaceURL: workspace,
            conversationId: UUID(),
            context: .reference(ChatReference(id: 7, title: "Paper", authors: "")))

        let home = await store.librarySessionIDs(
            ["home-session-1", "home-session-rotated", "reader-session", "unknown"],
            provider: .claude,
            workspaceURL: workspace)
        XCTAssertEqual(home, ["home-session-1", "home-session-rotated"])

        let reloaded = AssistantSessionAttributionStore(fileURL: file)
        let attribution = await reloaded.attribution(
            sessionID: "home-session-rotated",
            provider: .claude,
            workspaceURL: workspace)
        XCTAssertEqual(attribution?.conversationId, conversation)
        XCTAssertEqual(attribution?.context, .library)

        let bytes = try Data(contentsOf: file)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("home-session-1"), "raw provider IDs must be hashed")
        XCTAssertFalse(text.contains(workspace.path), "raw workspace paths must be hashed")
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
