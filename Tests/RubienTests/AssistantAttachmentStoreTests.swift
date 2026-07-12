#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

    func testRejectsNonUTF8AndOversizedText() async throws {
        let cases: [(String, Data, AssistantAttachmentStoreError)] = [
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

    func testProbesNonTextFilesAsImagesRegardlessOfExtension() async throws {
        let image = try makeImageData(width: 32, height: 24, alpha: false, type: .png)

        for name in ["extensionless", "misleading.data", "misleading.txt"] {
            let source = workspace.appendingPathComponent(name)
            try image.write(to: source)

            let attachment = try await store.stageFile(source, conversationID: UUID())

            XCTAssertEqual(attachment.kind, .image)
            XCTAssertEqual(attachment.mediaType, "image/jpeg")
            XCTAssertEqual(attachment.stagedURL.pathExtension, "jpg")
        }

        let unsupported = workspace.appendingPathComponent("not-an-image.csv")
        try Data("a,b".utf8).write(to: unsupported)
        let error = await XCTAssertThrowsErrorAsync(
            try await store.stageFile(unsupported, conversationID: UUID())
        )
        XCTAssertEqual(
            error as? AssistantAttachmentStoreError,
            .unsupported("not-an-image.csv")
        )
    }

    func testSparseOversizedSourcesAreRejectedWithoutEagerWholeFileReads() async throws {
        for (name, expectedError) in [
            ("huge.txt", AssistantAttachmentStoreError.tooLarge("huge.txt")),
            ("huge.bin", AssistantAttachmentStoreError.unsupported("huge.bin")),
        ] {
            let url = workspace.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 1_024 * 1_024 * 1_024)
            try handle.close()

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

    func testBoundsASCIIAndUnicodeStagedFilenamesToFilesystemComponentLimit() async throws {
        let names = [
            String(repeating: "a", count: 240) + ".txt",
            String(repeating: "界", count: 80) + ".txt",
        ]

        for (index, name) in names.enumerated() {
            let source = workspace.appendingPathComponent(name)
            try Data("hello".utf8).write(to: source)
            let id = UUID()

            let attachment = try await store.stageFile(
                source,
                id: id,
                conversationID: UUID()
            )

            XCTAssertTrue(attachment.stagedURL.lastPathComponent.hasPrefix(id.uuidString + "-"))
            XCTAssertEqual(attachment.stagedURL.pathExtension, "txt")
            XCTAssertLessThanOrEqual(attachment.stagedURL.lastPathComponent.utf8.count, 255)
            if index == 0 {
                XCTAssertEqual(attachment.stagedURL.lastPathComponent.utf8.count, 255)
            }
            XCTAssertEqual(try Data(contentsOf: attachment.stagedURL), Data("hello".utf8))
        }
    }

    func testRejectsSymlinkedManagedRootAndConversationBeforeWritingOutsideWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantAttachmentStoreOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let source = workspace.appendingPathComponent("safe.txt")
        try Data("safe".utf8).write(to: source)
        let rubienDirectory = workspace.appendingPathComponent(".rubien", isDirectory: true)
        try FileManager.default.createDirectory(at: rubienDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: rubienDirectory.appendingPathComponent("attachments"),
            withDestinationURL: outside
        )

        _ = await XCTAssertThrowsErrorAsync(
            try await store.stageFile(source, conversationID: UUID())
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])

        for item in try FileManager.default.contentsOfDirectory(
            at: outside,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: item)
        }

        try FileManager.default.removeItem(at: rubienDirectory.appendingPathComponent("attachments"))
        try FileManager.default.createDirectory(at: store.managedRoot, withIntermediateDirectories: true)
        let conversationID = UUID()
        try FileManager.default.createSymbolicLink(
            at: store.managedRoot.appendingPathComponent(conversationID.uuidString),
            withDestinationURL: outside
        )

        _ = await XCTAssertThrowsErrorAsync(
            try await store.stageFile(source, conversationID: conversationID)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testRemoveAndRehomeIgnoreCallerAttachmentsOutsideManagedRoot() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantAttachmentStoreOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let removeID = UUID()
        let removeURL = outside.appendingPathComponent("\(removeID.uuidString)-remove.txt")
        try Data("keep".utf8).write(to: removeURL)
        let removeAttachment = makeAttachment(id: removeID, stagedURL: removeURL)

        await store.removePending([removeAttachment])
        XCTAssertEqual(try Data(contentsOf: removeURL), Data("keep".utf8))

        let rehomeID = UUID()
        let rehomeURL = outside.appendingPathComponent("\(rehomeID.uuidString)-rehome.txt")
        try Data("keep".utf8).write(to: rehomeURL)
        let rehomeAttachment = makeAttachment(id: rehomeID, stagedURL: rehomeURL)

        _ = await XCTAssertThrowsErrorAsync(
            try await store.rehomePending([rehomeAttachment], to: UUID())
        )
        XCTAssertEqual(try Data(contentsOf: rehomeURL), Data("keep".utf8))
    }

    func testRemovePendingRejectsSymlinkedManagedRootBeforeDeletingTarget() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantAttachmentStoreOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let rubienDirectory = workspace.appendingPathComponent(".rubien", isDirectory: true)
        try FileManager.default.createDirectory(at: rubienDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: store.managedRoot,
            withDestinationURL: outside
        )
        let id = UUID()
        let outsideURL = outside.appendingPathComponent("\(id.uuidString)-keep.txt")
        try Data("keep".utf8).write(to: outsideURL)
        let attachment = makeAttachment(
            id: id,
            stagedURL: store.managedRoot.appendingPathComponent(outsideURL.lastPathComponent)
        )

        await store.removePending([attachment])

        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("keep".utf8))
    }

    func testRevalidatesResolvedContainmentAfterCreatingConversationDirectory() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantAttachmentStoreOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let swappingFileManager = DirectorySymlinkSwapFileManager(outside: outside)
        let swappingStore = AssistantAttachmentStore(
            workspaceURL: workspace,
            fileManager: swappingFileManager
        )
        let source = workspace.appendingPathComponent("swap.txt")
        try Data("safe".utf8).write(to: source)

        let error = await XCTAssertThrowsErrorAsync(
            try await swappingStore.stageFile(source, conversationID: UUID())
        )

        XCTAssertEqual(
            error as? AssistantAttachmentStoreError,
            .writeFailed("swap.txt")
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testRehomeRejectsManagedSymlinkWhoseResolvedSourceEscapesRoot() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantAttachmentStoreOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let sourceConversation = UUID()
        try FileManager.default.createDirectory(at: store.managedRoot, withIntermediateDirectories: true)
        let sourceDirectory = store.managedRoot
            .appendingPathComponent(sourceConversation.uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: sourceDirectory,
            withDestinationURL: outside
        )
        let id = UUID()
        let outsideURL = outside.appendingPathComponent("\(id.uuidString)-secret.txt")
        try Data("secret".utf8).write(to: outsideURL)
        let stagedURL = sourceDirectory.appendingPathComponent(outsideURL.lastPathComponent)
        let attachment = makeAttachment(id: id, stagedURL: stagedURL)
        let destinationConversation = UUID()

        _ = await XCTAssertThrowsErrorAsync(
            try await store.rehomePending([attachment], to: destinationConversation)
        )

        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("secret".utf8))
        let escapedCopy = store.managedRoot
            .appendingPathComponent(destinationConversation.uuidString)
            .appendingPathComponent(stagedURL.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedCopy.path))
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

    func testRehomeRetryReconcilesStaleDestinationAfterCleanupFailure() async throws {
        let failingFileManager = CommitCleanupFailureFileManager()
        let failingStore = AssistantAttachmentStore(
            workspaceURL: workspace,
            fileManager: failingFileManager
        )
        let sourceConversation = UUID()
        let destinationConversation = UUID()
        let firstSource = workspace.appendingPathComponent("retry-first.txt")
        let secondSource = workspace.appendingPathComponent("retry-second.txt")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let first = try await failingStore.stageFile(
            firstSource,
            conversationID: sourceConversation
        )
        let second = try await failingStore.stageFile(
            secondSource,
            conversationID: sourceConversation
        )

        _ = await XCTAssertThrowsErrorAsync(
            try await failingStore.rehomePending(
                [first, second],
                to: destinationConversation
            )
        )

        let staleDestination = failingStore.managedRoot
            .appendingPathComponent(destinationConversation.uuidString, isDirectory: true)
            .appendingPathComponent(first.stagedURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: staleDestination), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: first.stagedURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.stagedURL), Data("second".utf8))

        let retryStore = AssistantAttachmentStore(workspaceURL: workspace)
        let moved = try await retryStore.rehomePending(
            [first, second],
            to: destinationConversation
        )

        XCTAssertEqual(moved.map(\.id), [first.id, second.id])
        XCTAssertEqual(try Data(contentsOf: moved[0].stagedURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: moved[1].stagedURL), Data("second".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.stagedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.stagedURL.path))
    }

    func testOriginalCleanupFailureRollsBackCommittedDestinationsAndKeepsOriginalURLs() async throws {
        let failingFileManager = OriginalCleanupFailureFileManager()
        let failingStore = AssistantAttachmentStore(
            workspaceURL: workspace,
            fileManager: failingFileManager
        )
        let sourceConversation = UUID()
        let destinationConversation = UUID()
        let firstSource = workspace.appendingPathComponent("cleanup-first.txt")
        let secondSource = workspace.appendingPathComponent("cleanup-second.txt")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let first = try await failingStore.stageFile(firstSource, conversationID: sourceConversation)
        let second = try await failingStore.stageFile(secondSource, conversationID: sourceConversation)
        failingFileManager.failOnSecondOriginalRemoval(in: sourceConversation)

        _ = await XCTAssertThrowsErrorAsync(
            try await failingStore.rehomePending([first, second], to: destinationConversation)
        )

        XCTAssertEqual(try Data(contentsOf: first.stagedURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.stagedURL), Data("second".utf8))
        let destinationDirectory = failingStore.managedRoot
            .appendingPathComponent(destinationConversation.uuidString)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationDirectory
                    .appendingPathComponent(first.stagedURL.lastPathComponent).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationDirectory
                    .appendingPathComponent(second.stagedURL.lastPathComponent).path
            )
        )
    }

    func testFailedOriginalRestorationPreservesCommittedRecoveryCopy() async throws {
        let failingFileManager = OriginalCleanupFailureFileManager(
            failRestoration: true
        )
        let failingStore = AssistantAttachmentStore(
            workspaceURL: workspace,
            fileManager: failingFileManager
        )
        let sourceConversation = UUID()
        let destinationConversation = UUID()
        let firstSource = workspace.appendingPathComponent("restore-first.txt")
        let secondSource = workspace.appendingPathComponent("restore-second.txt")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let first = try await failingStore.stageFile(firstSource, conversationID: sourceConversation)
        let second = try await failingStore.stageFile(secondSource, conversationID: sourceConversation)
        failingFileManager.failOnSecondOriginalRemoval(in: sourceConversation)

        let error = await XCTAssertThrowsErrorAsync(
            try await failingStore.rehomePending([first, second], to: destinationConversation)
        )

        guard case .rehomeRecovered(let recovered) = error as? AssistantAttachmentStoreError else {
            return XCTFail("Expected recovered attachment ownership, got \(String(describing: error))")
        }
        XCTAssertEqual(recovered.map(\.id), [first.id, second.id])
        XCTAssertTrue(recovered.allSatisfy {
            FileManager.default.fileExists(atPath: $0.stagedURL.path)
        })
        let destinationDirectory = failingStore.managedRoot
            .appendingPathComponent(destinationConversation.uuidString)
        XCTAssertEqual(Set(recovered.map { $0.stagedURL.deletingLastPathComponent() }),
                       [destinationDirectory])
        XCTAssertEqual(try Data(contentsOf: recovered[0].stagedURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: recovered[1].stagedURL), Data("second".utf8))

        let retried = try await failingStore.rehomePending(
            recovered, to: destinationConversation
        )
        XCTAssertEqual(retried, recovered)
        await failingStore.removePending(retried)
        XCTAssertTrue(retried.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.stagedURL.path)
        })
    }

    func testDestinationCreationAndCopyFailuresAreNotReportedAsSourceUnreadable() async throws {
        let source = workspace.appendingPathComponent("destination.txt")
        try Data("hello".utf8).write(to: source)
        let directoryFailureStore = AssistantAttachmentStore(
            workspaceURL: workspace,
            fileManager: DirectoryCreationFailureFileManager()
        )

        let stageError = await XCTAssertThrowsErrorAsync(
            try await directoryFailureStore.stageFile(source, conversationID: UUID())
        )
        XCTAssertNotEqual(
            stageError as? AssistantAttachmentStoreError,
            .unreadable("destination.txt")
        )
        XCTAssertEqual(
            stageError as? AssistantAttachmentStoreError,
            .writeFailed("destination.txt")
        )

        let staged = try await store.stageFile(source, conversationID: UUID())
        let copyFailureStore = AssistantAttachmentStore(
            workspaceURL: workspace,
            fileManager: CopyFailureFileManager()
        )
        let copyError = await XCTAssertThrowsErrorAsync(
            try await copyFailureStore.rehomePending([staged], to: UUID())
        )
        XCTAssertNotEqual(
            copyError as? AssistantAttachmentStoreError,
            .unreadable("destination.txt")
        )
        XCTAssertEqual(
            copyError as? AssistantAttachmentStoreError,
            .writeFailed("destination.txt")
        )
        XCTAssertEqual(try Data(contentsOf: staged.stagedURL), Data("hello".utf8))
    }

    func testLargeOpaqueImageStagesAsBoundedJPEG() async throws {
        let source = workspace.appendingPathComponent("large.tiff")
        let original = try makeImageData(
            width: 4_000,
            height: 2_000,
            alpha: false,
            type: .tiff
        )
        try original.write(to: source)
        let attachment = try await store.stageFile(source, conversationID: UUID())

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mediaType, "image/jpeg")
        XCTAssertEqual(attachment.stagedURL.pathExtension, "jpg")
        XCTAssertLessThanOrEqual(
            attachment.byteCount,
            Int64(AssistantImageNormalizer.maxBytes)
        )
        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithURL(attachment.stagedURL as CFURL, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertLessThanOrEqual(
            properties[kCGImagePropertyPixelWidth] as? Int ?? .max,
            AssistantImageNormalizer.maxPixelSize
        )
        XCTAssertLessThanOrEqual(
            properties[kCGImagePropertyPixelHeight] as? Int ?? .max,
            AssistantImageNormalizer.maxPixelSize
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPastedTransparentImageUsesPNGAndCallerIdentity() async throws {
        let data = try makeImageData(width: 64, height: 64, alpha: true, type: .png)
        let id = UUID()
        let attachment = try await store.stageImageData(
            data,
            suggestedName: "clipboard.png",
            id: id,
            conversationID: UUID()
        )

        XCTAssertEqual(attachment.id, id)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mediaType, "image/png")
        XCTAssertEqual(attachment.stagedURL.pathExtension, "png")
        XCTAssertTrue(attachment.stagedURL.lastPathComponent.hasPrefix(id.uuidString + "-"))
        XCTAssertTrue(attachment.sourceIdentity.hasPrefix("clipboard:"))
    }

    func testTransparentImageFallsBackToWhiteCompositedJPEGWhenPNGIsTooLarge() throws {
        let data = try makeNoisyTransparentImageData(width: 512, height: 512)
        let png = try AssistantImageNormalizer.normalize(
            data,
            displayName: "noise.png",
            maxPixelSize: 512,
            maxBytes: 10 * 1_024 * 1_024
        )
        XCTAssertEqual(png.mediaType, "image/png")

        let fallback = try AssistantImageNormalizer.normalize(
            data,
            displayName: "noise.png",
            maxPixelSize: 512,
            maxBytes: png.data.count / 2
        )
        XCTAssertEqual(fallback.mediaType, "image/jpeg")
        XCTAssertLessThanOrEqual(fallback.data.count, png.data.count / 2)
        XCTAssertTrue(fallback.thumbnailDataURL.hasPrefix("data:image/jpeg;base64,"))
    }

    func testImageNormalizationHonorsOrientationAndBoundsThumbnail() throws {
        let data = try makeImageData(
            width: 120,
            height: 60,
            alpha: false,
            type: .jpeg,
            orientation: 6
        )
        let normalized = try AssistantImageNormalizer.normalize(
            data,
            displayName: "rotated.jpg"
        )

        XCTAssertEqual(normalized.width, 60)
        XCTAssertEqual(normalized.height, 120)
        XCTAssertTrue(normalized.thumbnailDataURL.hasPrefix("data:image/jpeg;base64,"))
        let thumbnail = try decodeDataURL(normalized.thumbnailDataURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, 160)
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight] as? Int ?? .max, 160)
    }

    func testInvalidAndImpossibleImageFailsLocallyWithFilename() async throws {
        let invalidError = await XCTAssertThrowsErrorAsync(
            try await store.stageImageData(
                Data("not image".utf8),
                suggestedName: "bad.png",
                conversationID: UUID()
            )
        )
        XCTAssertEqual(
            invalidError as? AssistantAttachmentStoreError,
            .imageDecode("bad.png")
        )

        XCTAssertThrowsError(
            try AssistantImageNormalizer.normalize(
                try makeImageData(width: 512, height: 512, alpha: false, type: .png),
                displayName: "x.png",
                maxPixelSize: 16,
                maxBytes: 8
            )
        ) { error in
            XCTAssertEqual(error as? AssistantAttachmentStoreError, .imageEncode("x.png"))
        }
    }
}

private func makeAttachment(id: UUID, stagedURL: URL) -> ChatAttachment {
    ChatAttachment(
        id: id,
        displayName: stagedURL.lastPathComponent,
        kind: .text,
        stagedURL: stagedURL,
        mediaType: "text/plain",
        byteCount: 4,
        sourceIdentity: stagedURL.path
    )
}

private func makeImageData(
    width: Int,
    height: Int,
    alpha: Bool,
    type: UTType,
    orientation: Int? = nil
) throws -> Data {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    let context = try XCTUnwrap(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        )
    )
    context.setFillColor(
        CGColor(
            colorSpace: colorSpace,
            components: alpha ? [0.15, 0.35, 0.75, 0.45] : [0.15, 0.35, 0.75, 1]
        )!
    )
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(
        CGColor(
            colorSpace: colorSpace,
            components: alpha ? [0.9, 0.2, 0.1, 0.7] : [0.9, 0.2, 0.1, 1]
        )!
    )
    context.fill(
        CGRect(
            x: width / 5,
            y: height / 4,
            width: max(width / 2, 1),
            height: max(height / 3, 1)
        )
    )

    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
    )
    let properties = orientation.map {
        [kCGImagePropertyOrientation: $0] as CFDictionary
    }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw ImageFixtureError.encode
    }
    return data as Data
}

private func decodeDataURL(_ value: String) throws -> Data {
    guard
        let comma = value.firstIndex(of: ","),
        let data = Data(base64Encoded: String(value[value.index(after: comma)...]))
    else {
        throw ImageFixtureError.invalidDataURL
    }
    return data
}

private func makeNoisyTransparentImageData(width: Int, height: Int) throws -> Data {
    var state: UInt32 = 0x6d2b_79f5
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        state = 1_664_525 &* state &+ 1_013_904_223
        let alpha = UInt8(truncatingIfNeeded: 128 + (state >> 25))
        for component in 0..<3 {
            state = 1_664_525 &* state &+ 1_013_904_223
            let value = UInt8(truncatingIfNeeded: state >> 24)
            pixels[offset + component] = UInt8(
                UInt16(value) * UInt16(alpha) / UInt16(UInt8.max)
            )
        }
        pixels[offset + 3] = alpha
    }

    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
    let image = try XCTUnwrap(
        CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    )
    let data = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ImageFixtureError.encode
    }
    return data as Data
}

private enum ImageFixtureError: Error {
    case encode
    case invalidDataURL
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

private final class CommitCleanupFailureFileManager: FileManager {
    private var moveCalls = 0
    private var didFailDestinationCleanup = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCalls += 1
        if moveCalls == 2 {
            throw InjectedFailure()
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        if
            !didFailDestinationCleanup,
            !URL.lastPathComponent.hasPrefix(".rehome-")
        {
            didFailDestinationCleanup = true
            throw InjectedFailure()
        }
        try super.removeItem(at: URL)
    }

    private struct InjectedFailure: Error {}
}

private final class OriginalCleanupFailureFileManager: FileManager {
    private let failRestoration: Bool
    private var sourceConversationComponent: String?
    private var originalRemovalCalls = 0
    private var didFailOriginalRemoval = false

    init(failRestoration: Bool = false) {
        self.failRestoration = failRestoration
        super.init()
    }

    func failOnSecondOriginalRemoval(in conversationID: UUID) {
        sourceConversationComponent = conversationID.uuidString
    }

    override func removeItem(at URL: URL) throws {
        if URL.deletingLastPathComponent().lastPathComponent == sourceConversationComponent {
            originalRemovalCalls += 1
            if originalRemovalCalls == 2 {
                didFailOriginalRemoval = true
                throw InjectedFailure()
            }
        }
        try super.removeItem(at: URL)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if failRestoration, didFailOriginalRemoval {
            throw InjectedFailure()
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    private struct InjectedFailure: Error {}
}

private final class DirectoryCreationFailureFileManager: FileManager {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw InjectedFailure()
    }

    private struct InjectedFailure: Error {}
}

private final class CopyFailureFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw InjectedFailure()
    }

    private struct InjectedFailure: Error {}
}

private final class DirectorySymlinkSwapFileManager: FileManager {
    private let outside: URL
    private var didSwap = false

    init(outside: URL) {
        self.outside = outside
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
        guard !didSwap, url.lastPathComponent != "attachments" else { return }
        didSwap = true
        try super.removeItem(at: url)
        try super.createSymbolicLink(at: url, withDestinationURL: outside)
    }
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
