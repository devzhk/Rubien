#if os(macOS)
import XCTest
import RubienCore
@testable import Rubien

@MainActor
final class SupplementAttachChoiceModelTests: XCTestCase {
    private let supplementURL = "https://openaccess.thecvf.com/content/CVPR2026/supplemental/SpeeDiff_supp.pdf"
    private typealias Outcome = AssistantSupplementAttacher.Outcome

    private func outcome(duplicate: Bool = false) -> Outcome {
        Outcome(
            attachmentSyncId: "att-1",
            parentReferenceId: 7,
            parentTitle: "SpeeDiff: Scalable Pixel-Anchored Diffusion",
            wasDuplicate: duplicate)
    }

    private func makeModel(
        suggestions: [ChatPaperAttachTarget.Suggestion] = [
            .init(referenceId: 7, title: "SpeeDiff: Scalable Pixel-Anchored Diffusion", reason: .assistant),
        ],
        looksSupplementary: Bool = true,
        title: String = "SpeeDiff — CVPR 2026 Supplementary Material",
        attach: @escaping SupplementAttachChoiceModel.AttachAction = { _, _, _ in
            throw CancellationError()
        },
        search: @escaping SupplementAttachChoiceModel.SearchAction = { _ in [] },
        open: @escaping SupplementAttachChoiceModel.OpenAction = { _ in }
    ) -> SupplementAttachChoiceModel {
        SupplementAttachChoiceModel(
            request: ChatPaperAddRequest(url: supplementURL, title: title, parentReferenceId: 7),
            resolution: .init(suggestions: suggestions, looksSupplementary: looksSupplementary),
            attach: attach,
            search: search,
            open: open)
    }

    // MARK: Defaults and labels

    func testDefaultSelectionFollowsResolutionPreselection() {
        let declared = makeModel(looksSupplementary: false)
        XCTAssertEqual(declared.choice, .attach(referenceId: 7))
        XCTAssertEqual(declared.primaryButtonTitle, "Attach")
        XCTAssertEqual(declared.attachmentName, "SpeeDiff — CVPR 2026 Supplementary Material")
        XCTAssertEqual(declared.subtitle, "openaccess.thecvf.com · PDF")

        let currentOnly = makeModel(
            suggestions: [.init(referenceId: 3, title: "Current", reason: .currentPaper)],
            looksSupplementary: false)
        XCTAssertEqual(currentOnly.choice, .newReference)
        XCTAssertEqual(currentOnly.primaryButtonTitle, "Continue…")
        XCTAssertNil(currentOnly.nameValidationMessage, "the name only matters for attach")

        let none = makeModel(suggestions: [])
        XCTAssertEqual(none.choice, .newReference)
    }

    func testButtonLabelAndNameValidationTrackSelection() {
        let model = makeModel()
        model.choice = .newReference
        XCTAssertEqual(model.primaryButtonTitle, "Continue…")
        model.attachmentName = "   "
        XCTAssertTrue(model.canPerformPrimary)

        model.choice = .attach(referenceId: 7)
        XCTAssertEqual(model.primaryButtonTitle, "Attach")
        XCTAssertNotNil(model.nameValidationMessage)
        XCTAssertFalse(model.canPerformPrimary)
        model.attachmentName = String(repeating: "n", count: 256)
        XCTAssertFalse(model.canPerformPrimary)
        model.attachmentName = "Supplement"
        XCTAssertTrue(model.canPerformPrimary)
    }

    func testContinueReturnsTheUnchangedAddSourceURLWithoutAttaching() {
        var attachCalls = 0
        let model = makeModel(attach: { _, _, _ in
            attachCalls += 1
            throw CancellationError()
        })
        model.choice = .newReference
        XCTAssertEqual(model.performPrimary(), .continueToNewReference(supplementURL))
        XCTAssertEqual(model.phase, .choosing)
        XCTAssertEqual(attachCalls, 0)
    }

    // MARK: Attach progress

    func testAttachProgressesToAttachedWithTrimmedName() async {
        var received: (String, Int64, String)?
        let model = makeModel(attach: { url, id, name in
            received = (url, id, name)
            return self.outcome()
        })
        model.attachmentName = "  Supplement  "
        XCTAssertEqual(model.performPrimary(), .attach)
        XCTAssertEqual(model.phase, .downloading)
        XCTAssertFalse(model.canPerformPrimary)
        await model.waitForAttach()

        XCTAssertEqual(received?.0, supplementURL)
        XCTAssertEqual(received?.1, 7)
        XCTAssertEqual(received?.2, "Supplement")
        XCTAssertEqual(model.phase, .finished(outcome()))
        XCTAssertEqual(model.resultMessage, "Attached to SpeeDiff")
    }

    func testDuplicateReportsAlreadyAttachedAndOpenUsesOutcome() async {
        var opened: Outcome?
        let model = makeModel(
            attach: { _, _, _ in self.outcome(duplicate: true) },
            open: { opened = $0 })
        model.performPrimary()
        await model.waitForAttach()
        XCTAssertEqual(model.resultMessage, "Already attached")

        await model.openAttachment()
        XCTAssertEqual(opened, outcome(duplicate: true))
        XCTAssertNil(model.openErrorMessage)
    }

    func testErrorThenRetrySucceedsAndOtherRowsStayUsable() async {
        var calls = 0
        let model = makeModel(
            suggestions: [
                .init(referenceId: 7, title: "SpeeDiff", reason: .assistant),
                .init(referenceId: 8, title: "Other", reason: .shownAbove),
            ],
            attach: { _, _, _ in
                calls += 1
                if calls == 1 { throw AssistantSupplementAttacher.AttachError.busy }
                return self.outcome()
            })
        model.performPrimary()
        await model.waitForAttach()
        XCTAssertEqual(model.phase, .failed("Another attachment operation is running. Try again."))
        XCTAssertTrue(model.canPerformPrimary, "Try again stays available")

        model.choice = .attach(referenceId: 8)
        XCTAssertEqual(model.phase, .choosing, "choosing another row clears the error")
        model.choice = .attach(referenceId: 7)
        model.retry()
        await model.waitForAttach()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.phase, .finished(outcome()))
    }

    func testParentDeletedWhileSheetIsOpenShowsError() async {
        let model = makeModel(attach: { _, _, _ in
            throw AssistantSupplementAttacher.AttachError.parentMissing
        })
        model.performPrimary()
        await model.waitForAttach()
        XCTAssertEqual(model.phase, .failed("The reference no longer exists."))
    }

    func testCancelStopsTheAttachTaskAndReturnsToChoices() async {
        let started = expectation(description: "attach started")
        var sawCancellation = false
        let model = makeModel(attach: { _, _, _ in
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                sawCancellation = true
                throw error
            }
            return self.outcome()
        })
        model.performPrimary()
        await fulfillment(of: [started], timeout: 2)
        model.cancelAttach()
        XCTAssertEqual(model.phase, .choosing)
        XCTAssertTrue(model.canPerformPrimary)
        // Give the cancelled task a moment to unwind.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sawCancellation)
        XCTAssertEqual(model.phase, .choosing)
    }

    // MARK: Search

    func testSearchResultSelectsAnotherReference() async {
        let model = makeModel(search: { query in
            XCTAssertEqual(query, "graph")
            return [
                ChatReference(id: 21, title: "Graph Networks", authors: ""),
                ChatReference(id: 7, title: "SpeeDiff", authors: ""),
            ]
        })
        model.searchQuery = "  graph "
        await model.runSearch()
        XCTAssertEqual(model.searchResults.map(\.referenceId), [21, 7])

        model.selectSearchResult(model.searchResults[0])
        XCTAssertEqual(model.choice, .attach(referenceId: 21))
        XCTAssertTrue(model.isSearchedTargetSelected)
        XCTAssertEqual(model.title(forReference: 21), "Graph Networks")
        XCTAssertEqual(model.primaryButtonTitle, "Attach")
        XCTAssertEqual(model.searchResults, [])

        model.selectSearchResult(.init(referenceId: 7, title: "SpeeDiff"))
        XCTAssertEqual(model.choice, .attach(referenceId: 7))
        XCTAssertFalse(model.isSearchedTargetSelected, "a suggested row is selected in place")
    }
}

@MainActor
final class AssistantSupplementAttacherTests: XCTestCase {
    private var root: URL!
    private let url = "https://example.com/files/paper-supp.md"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rubien-supplement-attacher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sourceFile() throws -> URL {
        let file = root.appendingPathComponent("paper-supp.md")
        try Data("# Supplement\n".utf8).write(to: file)
        return file
    }

    private final class Recorder: @unchecked Sendable {
        var temporaryDirectory: URL?
        var imported: (URL, Int64, String?)?
        var parentExists = true
        var parentChecks = 0
    }

    private func dependencies(
        _ recorder: Recorder,
        source: URL,
        beforeReturn: @escaping @Sendable () -> Void = {},
        importResult: @escaping @Sendable () throws -> AssistantSupplementAttacher.ImportedAttachment = {
            .init(syncId: "att-9", wasDuplicate: false)
        }
    ) -> AssistantSupplementAttacher.Dependencies {
        AssistantSupplementAttacher.Dependencies(
            parentTitle: { _ in
                recorder.parentChecks += 1
                return recorder.parentExists ? "Parent: Paper" : nil
            },
            materialize: { _ in
                let copy = try ImportSourceMaterializer.materializeTemporaryCopy(localFileURL: source)
                recorder.temporaryDirectory = copy.temporaryDirectoryURL
                beforeReturn()
                return copy
            },
            importFile: { file, id, name in
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
                recorder.imported = (file, id, name)
                return try importResult()
            })
    }

    func testAttachImportsWithNameAndRemovesTemporaryDownload() async throws {
        let recorder = Recorder()
        let attacher = AssistantSupplementAttacher(
            dependencies: dependencies(recorder, source: try sourceFile()))

        let outcome = try await attacher.attach(url: url, to: 7, displayName: "  Supplement ")

        XCTAssertEqual(outcome, .init(
            attachmentSyncId: "att-9", parentReferenceId: 7,
            parentTitle: "Parent: Paper", wasDuplicate: false))
        XCTAssertEqual(recorder.imported?.1, 7)
        XCTAssertEqual(recorder.imported?.2, "Supplement")
        XCTAssertEqual(recorder.parentChecks, 2, "the parent is re-checked after the download")
        let temporary = try XCTUnwrap(recorder.temporaryDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testCancelAfterDownloadCleansTemporaryDirectoryWithoutImporting() async throws {
        let recorder = Recorder()
        let attacher = AssistantSupplementAttacher(dependencies: dependencies(
            recorder,
            source: try sourceFile(),
            beforeReturn: { withUnsafeCurrentTask { $0?.cancel() } }))

        do {
            _ = try await attacher.attach(url: url, to: 7, displayName: nil)
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        XCTAssertNil(recorder.imported)
        let temporary = try XCTUnwrap(recorder.temporaryDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testParentDeletedDuringDownloadFailsAndCleansUp() async throws {
        let recorder = Recorder()
        let attacher = AssistantSupplementAttacher(dependencies: dependencies(
            recorder,
            source: try sourceFile(),
            beforeReturn: { recorder.parentExists = false }))

        do {
            _ = try await attacher.attach(url: url, to: 7, displayName: nil)
            XCTFail("expected parentMissing")
        } catch let error as AssistantSupplementAttacher.AttachError {
            XCTAssertEqual(error, .parentMissing)
        }
        XCTAssertNil(recorder.imported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recorder.temporaryDirectory).path))
    }

    func testBusyStoreAndMissingReferenceMapToRetryableErrors() async throws {
        for (storeError, expected) in [
            (ReferenceAttachmentError.busy, AssistantSupplementAttacher.AttachError.busy),
            (ReferenceAttachmentError.missingReference, AssistantSupplementAttacher.AttachError.parentMissing),
        ] {
            let recorder = Recorder()
            let attacher = AssistantSupplementAttacher(dependencies: dependencies(
                recorder, source: try sourceFile(), importResult: { throw storeError }))
            do {
                _ = try await attacher.attach(url: url, to: 7, displayName: nil)
                XCTFail("expected \(expected)")
            } catch let error as AssistantSupplementAttacher.AttachError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: try XCTUnwrap(recorder.temporaryDirectory).path))
        }
        XCTAssertEqual(
            AssistantSupplementAttacher.AttachError.busy.localizedDescription,
            "Another attachment operation is running. Try again.")
    }

    func testUnsafeURLMissingParentAndInvalidNameFailBeforeDownloading() async throws {
        let recorder = Recorder()
        let attacher = AssistantSupplementAttacher(
            dependencies: dependencies(recorder, source: try sourceFile()))

        do {
            _ = try await attacher.attach(url: "file:///tmp/a.md", to: 7, displayName: nil)
            XCTFail("expected unsafeURL")
        } catch let error as AssistantSupplementAttacher.AttachError {
            XCTAssertEqual(error, .unsafeURL)
        }
        do {
            _ = try await attacher.attach(url: url, to: 7, displayName: "   ")
            XCTFail("expected invalidName")
        } catch let error as ReferenceAttachmentError {
            XCTAssertEqual(error, .invalidName)
        }
        recorder.parentExists = false
        do {
            _ = try await attacher.attach(url: url, to: 7, displayName: nil)
            XCTFail("expected parentMissing")
        } catch let error as AssistantSupplementAttacher.AttachError {
            XCTAssertEqual(error, .parentMissing)
        }
        XCTAssertNil(recorder.temporaryDirectory, "nothing was downloaded")
    }
}
#endif
