import XCTest
import Foundation

final class SyncStatusCommandTests: XCTestCase {

    private var cliURL: URL {
        URL(fileURLWithPath: ".build/debug/rubien-cli")
    }

    func testSyncStatusReturnsJSONWithExpectedFields() throws {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["sync", "status"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)

        // Required fields per spec.
        for key in [
            "enabled", "containerIdentifier", "entitlementPresent",
            "iCloudAccountAvailable", "appLockHeld", "baselineState",
            "dirtyByEntityType", "tombstoneCount", "syncEngineState",
            "schemaVersion"
        ] {
            XCTAssertNotNil(json?[key], "missing field '\(key)' in JSON output")
        }
    }
}
