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
