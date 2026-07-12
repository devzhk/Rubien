#if os(macOS)
import Foundation
import XCTest
@testable import Rubien

final class AssistantAttachmentStoreTests: XCTestCase {
    private var workspace: URL!
    private var store: AssistantAttachmentStore!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantAttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        store = AssistantAttachmentStore(workspaceURL: workspace)
    }

    override func tearDownWithError() throws {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspace = nil
        store = nil
    }

    func testStagesUTF8MarkdownWithoutChangingSource() async throws {
        let source = workspace.appendingPathComponent("source.md")
        let original = Data("# Café\n".utf8)
        try original.write(to: source)
        let conversation = UUID()
        let attachment = try await store.stageFile(source, conversationID: conversation)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.mediaType, "text/markdown")
        XCTAssertEqual(try Data(contentsOf: attachment.stagedURL), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(
            attachment.stagedURL.path.contains(
                "/.rubien/attachments/\(conversation.uuidString)/"
            )
        )
        XCTAssertTrue(
            attachment.stagedURL.lastPathComponent.hasPrefix(attachment.id.uuidString + "-")
        )
    }

    func testRejectsCSVNonUTF8AndOversizedText() async throws {
        let cases: [(String, Data, AssistantAttachmentStoreError)] = [
            ("x.csv", Data("a,b".utf8), .unsupported("x.csv")),
            ("x.txt", Data([0xff, 0xfe, 0xfd]), .nonUTF8("x.txt")),
            (
                "large.md",
                Data(repeating: 0x61, count: Int(AssistantAttachmentStore.maxTextBytes + 1)),
                .tooLarge("large.md")
            ),
        ]

        for (name, data, expectedError) in cases {
            let url = workspace.appendingPathComponent(name)
            try data.write(to: url)
            let error = await XCTAssertThrowsErrorAsync(
                try await store.stageFile(url, conversationID: UUID())
            )
            XCTAssertEqual(error as? AssistantAttachmentStoreError, expectedError)
        }
    }

    func testAcceptsBOMAndExactFiveMiBBoundary() async throws {
        let bomURL = workspace.appendingPathComponent("bom.markdown")
        let bom = Data([0xef, 0xbb, 0xbf]) + Data("hello".utf8)
        try bom.write(to: bomURL)
        let bomAttachment = try await store.stageFile(bomURL, conversationID: UUID())
        XCTAssertEqual(try Data(contentsOf: bomAttachment.stagedURL), bom)
        XCTAssertEqual(bomAttachment.mediaType, "text/markdown")

        let boundaryURL = workspace.appendingPathComponent("boundary.txt")
        let boundary = Data(repeating: 0x61, count: Int(AssistantAttachmentStore.maxTextBytes))
        try boundary.write(to: boundaryURL)
        let boundaryAttachment = try await store.stageFile(boundaryURL, conversationID: UUID())
        XCTAssertEqual(boundaryAttachment.byteCount, AssistantAttachmentStore.maxTextBytes)
        XCTAssertEqual(boundaryAttachment.mediaType, "text/plain")
    }

    func testRejectsDirectoriesPackagesAndSymbolicLinksBeforeReading() async throws {
        let directory = workspace.appendingPathComponent("folder.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let directoryError = await XCTAssertThrowsErrorAsync(
            try await store.stageFile(directory, conversationID: UUID())
        )
        XCTAssertEqual(
            directoryError as? AssistantAttachmentStoreError,
            .notRegularFile("folder.txt")
        )

        let package = workspace.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let packageError = await XCTAssertThrowsErrorAsync(
            try await store.stageFile(package, conversationID: UUID())
        )
        XCTAssertEqual(
            packageError as? AssistantAttachmentStoreError,
            .notRegularFile("Example.app")
        )

        let target = workspace.appendingPathComponent("target.txt")
        try Data("secret".utf8).write(to: target)
        let symlink = workspace.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let symlinkError = await XCTAssertThrowsErrorAsync(
            try await store.stageFile(symlink, conversationID: UUID())
        )
        XCTAssertEqual(
            symlinkError as? AssistantAttachmentStoreError,
            .notRegularFile("link.txt")
        )
    }

    func testUsesCallerIDAndSanitizesStagedBasename() async throws {
        let source = workspace.appendingPathComponent("line\nbreak.txt")
        try Data("hello".utf8).write(to: source)
        let id = UUID()
        let attachment = try await store.stageFile(source, id: id, conversationID: UUID())

        XCTAssertEqual(attachment.id, id)
        XCTAssertEqual(attachment.displayName, "line\nbreak.txt")
        XCTAssertTrue(attachment.stagedURL.lastPathComponent.hasPrefix(id.uuidString + "-"))
        XCTAssertFalse(attachment.stagedURL.lastPathComponent.contains("\n"))
        XCTAssertEqual(attachment.sourceIdentity, source.standardizedFileURL.path)
    }

    func testRehomeThenRemovePendingPreservesIdentityAndMetadata() async throws {
        let source = workspace.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: source)
        let first = try await store.stageFile(source, conversationID: UUID())
        let moved = try await store.rehomePending([first], to: UUID())

        XCTAssertEqual(moved[0].id, first.id)
        XCTAssertEqual(moved[0].displayName, first.displayName)
        XCTAssertEqual(moved[0].mediaType, first.mediaType)
        XCTAssertEqual(moved[0].byteCount, first.byteCount)
        XCTAssertEqual(moved[0].sourceIdentity, first.sourceIdentity)
        XCTAssertEqual(moved[0].thumbnailDataURL, first.thumbnailDataURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved[0].stagedURL.path))

        await store.removePending(moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved[0].stagedURL.path))
    }

    func testFailedRehomeLeavesEveryOriginalReadableAfterPreparationOrCommit() async throws {
        for failurePhase in RehomeFailureFileManager.FailurePhase.allCases {
            let failingFileManager = RehomeFailureFileManager(failurePhase: failurePhase)
            let store = AssistantAttachmentStore(
                workspaceURL: workspace,
                fileManager: failingFileManager
            )
            let conversation = UUID()
            let prefix = String(describing: failurePhase)
            let firstSource = workspace.appendingPathComponent("\(prefix)-first.txt")
            let secondSource = workspace.appendingPathComponent("\(prefix)-second.txt")
            try Data("first".utf8).write(to: firstSource)
            try Data("second".utf8).write(to: secondSource)
            let first = try await store.stageFile(firstSource, conversationID: conversation)
            let second = try await store.stageFile(secondSource, conversationID: conversation)

            _ = await XCTAssertThrowsErrorAsync(
                try await store.rehomePending([first, second], to: UUID())
            )

            XCTAssertEqual(failingFileManager.preparationCalls, 2)
            XCTAssertEqual(try Data(contentsOf: first.stagedURL), Data("first".utf8))
            XCTAssertEqual(try Data(contentsOf: second.stagedURL), Data("second".utf8))
        }
    }

    func testImageEntryPointUsesFinalStubErrorUntilTaskThree() async throws {
        let id = UUID()
        let error = await XCTAssertThrowsErrorAsync(
            try await store.stageImageData(
                Data(),
                suggestedName: "photo.png",
                id: id,
                conversationID: UUID()
            )
        )
        XCTAssertEqual(error as? AssistantAttachmentStoreError, .imageDecode("photo.png"))
    }
}

private final class RehomeFailureFileManager: FileManager {
    enum FailurePhase: CaseIterable {
        case preparation
        case commit
    }

    private let failurePhase: FailurePhase
    private(set) var preparationCalls = 0
    private var moveCalls = 0

    init(failurePhase: FailurePhase) {
        self.failurePhase = failurePhase
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        preparationCalls += 1
        if failurePhase == .preparation, preparationCalls == 2 {
            throw InjectedFailure()
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCalls += 1
        if failurePhase == .commit, moveCalls == 2 {
            throw InjectedFailure()
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    private struct InjectedFailure: Error {}
}

@discardableResult
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> (any Error)? {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
#endif
