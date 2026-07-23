import XCTest
@testable import RubienCore

final class AssistantExecutionLockTests: XCTestCase {
    func testLockIsExclusiveAndReleasedWithOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-assistant-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var first: AssistantLibraryExecutionLock? = try XCTUnwrap(
            AssistantLibraryExecutionLock.tryAcquire(
                libraryRoot: root,
                ownerDescription: "first"
            )
        )
        XCTAssertNil(try AssistantLibraryExecutionLock.tryAcquire(
            libraryRoot: root,
            ownerDescription: "second"
        ))
        XCTAssertTrue(
            AssistantLibraryExecutionLock.diagnosticOwner(libraryRoot: root)?
                .contains("owner=first") == true
        )

        first?.release()
        first = nil
        let second = try XCTUnwrap(AssistantLibraryExecutionLock.tryAcquire(
            libraryRoot: root,
            ownerDescription: "second"
        ))
        second.release()
    }

    func testLockRefusesSymlinkInsteadOfTruncatingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubien-assistant-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target.txt")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(AssistantLibraryExecutionLock.filename),
            withDestinationURL: target
        )

        XCTAssertThrowsError(try AssistantLibraryExecutionLock.tryAcquire(
            libraryRoot: root,
            ownerDescription: "test"
        ))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep me")
    }
}
