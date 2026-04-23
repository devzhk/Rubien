import XCTest
@testable import RubienSync

final class SyncConstantsTests: XCTestCase {

    func testContainerIdentifierFallsBackToDefault() {
        unsetenv("RUBIEN_CLOUDKIT_CONTAINER")
        XCTAssertEqual(
            SyncConstants.containerIdentifier,
            "iCloud.com.rubien.app",
            "without override, constant returns the production default"
        )
    }

    func testContainerIdentifierReadsEnvVar() {
        setenv("RUBIEN_CLOUDKIT_CONTAINER", "iCloud.test.override", 1)
        defer { unsetenv("RUBIEN_CLOUDKIT_CONTAINER") }
        XCTAssertEqual(SyncConstants.containerIdentifier, "iCloud.test.override")
    }
}
