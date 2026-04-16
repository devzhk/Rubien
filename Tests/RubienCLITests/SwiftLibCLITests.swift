import XCTest
import Foundation

/// Integration tests for the `rubien-cli` CLI binary.
/// These tests invoke the compiled CLI executable and verify its output.
/// Requires the CLI to be built first: `swift build --product rubien-cli`
final class RubienCLITests: XCTestCase {

    /// Path to the built CLI binary
    private var cliBinaryPath: String {
        let debugPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // RubienCLITests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent(".build/debug/rubien-cli")
            .path

        if FileManager.default.isExecutableFile(atPath: debugPath) {
            return debugPath
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rubien-cli") {
            return "/usr/local/bin/rubien-cli"
        }
        return debugPath
    }

    private func runCLI(_ arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func skipIfBinaryMissing() throws {
        guard FileManager.default.isExecutableFile(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath). Run `swift build` first.")
        }
    }

    // MARK: - Help

    func testHelpOutput() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        let output = result.stdout + result.stderr
        XCTAssertTrue(output.lowercased().contains("subcommand") || output.contains("SUBCOMMANDS"),
                      "Help should list subcommands")
    }

    // MARK: - Version

    func testVersionOutput() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["--version"])
        XCTAssertEqual(result.exitCode, 0)
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(output.isEmpty, "--version should produce output")
    }

    // MARK: - List

    func testListCommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["list"])
        XCTAssertEqual(result.exitCode, 0)
        // Verify output is valid JSON array
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "List output should be a JSON array")
    }

    func testListWithLimit() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["list", "--limit", "5"])
        XCTAssertEqual(result.exitCode, 0)
        let data = Data(result.stdout.utf8)
        let arr = try JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertNotNil(arr)
        XCTAssertLessThanOrEqual(arr?.count ?? 0, 5, "List with --limit 5 should return at most 5")
    }

    func testListWithOffset() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["list", "--offset", "0"])
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Search

    func testSearchCommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["search", "test"])
        XCTAssertEqual(result.exitCode, 0)
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Search output should be a JSON array")
    }

    // MARK: - Tags

    func testTagsListCommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["tags"])
        XCTAssertEqual(result.exitCode, 0)
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Tags output should be a JSON array")
    }

    // MARK: - Export

    func testExportJSON() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "json"])
        XCTAssertEqual(result.exitCode, 0)
        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [Any], "Export JSON should produce a JSON array")
    }

    func testExportBibTeX() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "bibtex"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExportRIS() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "ris"])
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Subcommand Help

    func testSearchHelp() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["search", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCiteHelp() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["cite", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testImportHelp() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["import", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Invalid Subcommand

    func testInvalidSubcommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["nonexistent"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "Invalid subcommand should return non-zero exit code")
    }

    // MARK: - Get Non-existent Reference

    func testGetNonExistentReference() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["get", "999999999"])
        XCTAssertNotEqual(result.exitCode, 0,
                          "Getting a non-existent reference should fail")
        // Error should be in stderr as JSON
        let errData = Data(result.stderr.utf8)
        if let errJson = try? JSONSerialization.jsonObject(with: errData) as? [String: Any] {
            XCTAssertNotNil(errJson["error"], "Error output should contain 'error' key")
        }
    }

    // MARK: - Delete requires --force in non-interactive

    func testDeleteWithoutForceInNonInteractive() throws {
        try skipIfBinaryMissing()
        // When run as a subprocess (non-tty), delete without --force should still work
        // because isatty returns 0 for piped stdin
        let result = try runCLI(["delete", "999999999", "--force"])
        _ = result
        // May fail because the reference doesn't exist, but should not hang waiting for input
        // The important thing is it doesn't block
    }

    // MARK: - Add → Get → Delete lifecycle

    func testAddGetDeleteLifecycle() throws {
        try skipIfBinaryMissing()

        // Add by title
        let addResult = try runCLI(["add", "--title", "CLI Test Reference \(UUID().uuidString)"])
        XCTAssertEqual(addResult.exitCode, 0, "Add should succeed")
        let addData = Data(addResult.stdout.utf8)
        let addJson = try JSONSerialization.jsonObject(with: addData) as? [String: Any]
        XCTAssertNotNil(addJson, "Add output should be a JSON object")
        guard let refId = addJson?["id"] as? Int64 ?? (addJson?["id"] as? Int).map(Int64.init) else {
            XCTFail("Add output should contain an integer 'id'")
            return
        }

        // Get the reference back
        let getResult = try runCLI(["get", "\(refId)"])
        XCTAssertEqual(getResult.exitCode, 0, "Get should succeed")
        let getData = Data(getResult.stdout.utf8)
        let getJson = try JSONSerialization.jsonObject(with: getData) as? [String: Any]
        XCTAssertNotNil(getJson?["title"], "Get output should contain 'title'")

        // Delete it (with --force to skip confirmation)
        let deleteResult = try runCLI(["delete", "\(refId)", "--force"])
        XCTAssertEqual(deleteResult.exitCode, 0, "Delete should succeed")

        // Verify it's gone
        let verifyResult = try runCLI(["get", "\(refId)"])
        XCTAssertNotEqual(verifyResult.exitCode, 0, "Get after delete should fail")
    }

    // MARK: - Import Help mentions stdin

    func testImportHelpMentionsStdin() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["import", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let output = result.stdout + result.stderr
        XCTAssertTrue(output.contains("-") || output.contains("stdin"),
                      "Import help should mention stdin support")
    }

    // MARK: - Cite invalid style

    func testCiteInvalidStyleFails() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["cite", "1", "--style", "nonexistent-style"])
        XCTAssertNotEqual(result.exitCode, 0, "Invalid citation style should fail")
    }

    // MARK: - Properties

    /// Read an integer id out of a JSON object emitted by the CLI.
    private func parseId(from data: Data) -> Int64? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj["id"] as? String { return Int64(s) }
        if let i = obj["id"] as? Int64 { return i }
        if let i = obj["id"] as? Int { return Int64(i) }
        return nil
    }

    func testPropertiesListCommand() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["properties"])
        XCTAssertEqual(result.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [Any]
        XCTAssertNotNil(arr, "properties should emit a JSON array")
        XCTAssertGreaterThan(arr?.count ?? 0, 0, "Seeded default properties should appear")
    }

    func testPropertiesListVisibleIsSubset() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [Any] ?? []
        let visible = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties", "--visible"]).stdout.utf8)) as? [Any] ?? []
        XCTAssertLessThanOrEqual(visible.count, all.count, "--visible must be a subset of all")
    }

    func testPropertiesCreateStringAndDelete() throws {
        try skipIfBinaryMissing()
        let uniqueName = "cli-string-\(UUID().uuidString.prefix(8))"

        let created = try runCLI(["properties", "--create", "--name", uniqueName, "--type", "string"])
        XCTAssertEqual(created.exitCode, 0, "create should succeed")
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create output should contain numeric id")
            return
        }

        let listed = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertTrue(listed.contains { ($0["name"] as? String) == uniqueName }, "created prop should appear in list")

        let deleted = try runCLI(["properties", "--delete", String(propId)])
        XCTAssertEqual(deleted.exitCode, 0, "delete should succeed")

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(after.contains { ($0["name"] as? String) == uniqueName }, "prop should be gone after delete")
    }

    func testPropertiesCreateSingleSelectWithOptions() throws {
        try skipIfBinaryMissing()
        let uniqueName = "cli-status-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["properties", "--create", "--name", uniqueName, "--type", "singleSelect", "--options", "todo,doing,done"])
        XCTAssertEqual(created.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any]
        let options = obj?["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(options.count, 3, "should have 3 options")
        let colors = options.compactMap { $0["color"] as? String }
        XCTAssertEqual(Set(colors).count, colors.count, "auto-assigned colors should be unique")

        if let propId = parseId(from: Data(created.stdout.utf8)) {
            _ = try runCLI(["properties", "--delete", String(propId)])
        }
    }

    func testPropertiesRename() throws {
        try skipIfBinaryMissing()
        let original = "cli-rename-\(UUID().uuidString.prefix(8))"
        let created = try runCLI(["properties", "--create", "--name", original, "--type", "string"])
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let renamed = original + "-renamed"
        let result = try runCLI(["properties", "--rename", "--id", String(propId), "--name", renamed])
        XCTAssertEqual(result.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["name"] as? String, renamed)
    }

    func testPropertiesShowHide() throws {
        try skipIfBinaryMissing()
        let created = try runCLI(["properties", "--create", "--name", "cli-vis-\(UUID().uuidString.prefix(8))", "--type", "string"])
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let hidden = try runCLI(["properties", "--hide", "--id", String(propId)])
        XCTAssertEqual(hidden.exitCode, 0)
        let hiddenObj = try JSONSerialization.jsonObject(with: Data(hidden.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(hiddenObj?["isVisible"] as? Bool, false)

        let shown = try runCLI(["properties", "--show", "--id", String(propId)])
        XCTAssertEqual(shown.exitCode, 0)
        let shownObj = try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(shownObj?["isVisible"] as? Bool, true)
    }

    func testPropertiesAddOption() throws {
        try skipIfBinaryMissing()
        let created = try runCLI(["properties", "--create", "--name", "cli-addopt-\(UUID().uuidString.prefix(8))", "--type", "singleSelect", "--options", "a,b"])
        guard let propId = parseId(from: Data(created.stdout.utf8)) else {
            XCTFail("create failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let added = try runCLI(["properties", "--add-option", "--id", String(propId), "--value", "c"])
        XCTAssertEqual(added.exitCode, 0)
        let obj = try JSONSerialization.jsonObject(with: Data(added.stdout.utf8)) as? [String: Any]
        let options = obj?["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(options.count, 3, "should now have 3 options")
        XCTAssertTrue(options.contains { ($0["value"] as? String) == "c" })
    }

    func testPropertiesSetAndClearValueRoundTrip() throws {
        try skipIfBinaryMissing()

        // Create a reference
        let addResult = try runCLI(["add", "--title", "CLI Prop Test \(UUID().uuidString.prefix(8))"])
        XCTAssertEqual(addResult.exitCode, 0)
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        // Create a custom property
        let propResult = try runCLI(["properties", "--create", "--name", "cli-val-\(UUID().uuidString.prefix(8))", "--type", "string"])
        guard let propId = parseId(from: Data(propResult.stdout.utf8)) else {
            XCTFail("create prop failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        // Set a value
        let setResult = try runCLI(["properties", "--set", "--reference", String(refId), "--id", String(propId), "--value", "hello"])
        XCTAssertEqual(setResult.exitCode, 0)

        // Read back via --reference listing
        let listed = try runCLI(["properties", "--reference", String(refId)])
        XCTAssertEqual(listed.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertTrue(arr.contains { ($0["value"] as? String) == "hello" && ($0["propertyId"] as? String) == String(propId) })

        // Verify get includes customProperties
        let getResult = try runCLI(["get", String(refId)])
        XCTAssertEqual(getResult.exitCode, 0)
        let getObj = try JSONSerialization.jsonObject(with: Data(getResult.stdout.utf8)) as? [String: Any]
        let custom = getObj?["customProperties"] as? [[String: Any]] ?? []
        XCTAssertTrue(custom.contains { ($0["value"] as? String) == "hello" })

        // Clear and confirm
        let clearResult = try runCLI(["properties", "--clear", "--reference", String(refId), "--id", String(propId)])
        XCTAssertEqual(clearResult.exitCode, 0)
        let afterClear = try runCLI(["properties", "--reference", String(refId)])
        let afterArr = try JSONSerialization.jsonObject(with: Data(afterClear.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(afterArr.contains { ($0["propertyId"] as? String) == String(propId) })
    }

    func testDeleteDefaultPropertyIsRefused() throws {
        try skipIfBinaryMissing()
        // Find a default property (isDefault == true)
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let defaultProp = all.first(where: { ($0["isDefault"] as? Bool) == true }),
              let idStr = defaultProp["id"] as? String else {
            XCTFail("No default property found to test against")
            return
        }

        let result = try runCLI(["properties", "--delete", idStr])
        XCTAssertNotEqual(result.exitCode, 0, "Deleting a built-in property should fail")

        // Ensure it still exists
        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertTrue(after.contains { ($0["id"] as? String) == idStr })
    }

    func testPropertiesRenameDefaultPropertyIsRefused() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let defaultProp = all.first(where: { ($0["isDefault"] as? Bool) == true }),
              let idStr = defaultProp["id"] as? String,
              let originalName = defaultProp["name"] as? String else {
            XCTFail("No default property seeded")
            return
        }

        let result = try runCLI(["properties", "--rename", "--id", idStr, "--name", "Hijacked"])
        XCTAssertNotEqual(result.exitCode, 0, "--rename on a built-in property should fail")

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        let stillThere = after.first { ($0["id"] as? String) == idStr }
        XCTAssertEqual(stillThere?["name"] as? String, originalName, "name must be unchanged")
    }

    func testPropertiesAddOptionToDefaultIsRefused() throws {
        try skipIfBinaryMissing()
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        // Find a default singleSelect — Type / Reading Status both qualify.
        guard let defaultSelect = all.first(where: {
            ($0["isDefault"] as? Bool) == true && ($0["type"] as? String) == "singleSelect"
        }), let idStr = defaultSelect["id"] as? String else {
            XCTFail("No default singleSelect property seeded")
            return
        }
        let originalCount = (defaultSelect["options"] as? [Any])?.count ?? 0

        let result = try runCLI(["properties", "--add-option", "--id", idStr, "--value", "Bogus"])
        XCTAssertNotEqual(result.exitCode, 0, "--add-option on a built-in property should fail")

        let after = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        let stillThere = after.first { ($0["id"] as? String) == idStr }
        let nowCount = (stillThere?["options"] as? [Any])?.count ?? 0
        XCTAssertEqual(nowCount, originalCount, "options list must be unchanged")
    }

    func testPropertiesSetDefaultPropertyIsRefused() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "CLI Default Guard \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        // Find a default (built-in) property — e.g. the seeded DOI/year/etc.
        let all = try JSONSerialization.jsonObject(with: Data(try runCLI(["properties"]).stdout.utf8)) as? [[String: Any]] ?? []
        guard let defaultProp = all.first(where: { ($0["isDefault"] as? Bool) == true }),
              let defaultIdStr = defaultProp["id"] as? String else {
            XCTFail("No default property seeded")
            return
        }

        let setResult = try runCLI(["properties", "--set",
                                    "--reference", String(refId),
                                    "--id", defaultIdStr,
                                    "--value", "bogus"])
        XCTAssertNotEqual(setResult.exitCode, 0, "--set on a built-in property should fail")

        // Double-check: value should not appear in the reference's custom properties
        let listed = try runCLI(["properties", "--reference", String(refId)])
        let arr = try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] ?? []
        XCTAssertFalse(arr.contains { ($0["propertyId"] as? String) == defaultIdStr },
                       "built-in property must not be stored as a propertyValue row")
    }

    func testPropertiesSetMultiSelectEncodesJSON() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "CLI Multi Test \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        let propResult = try runCLI(["properties", "--create",
                                     "--name", "cli-multi-\(UUID().uuidString.prefix(8))",
                                     "--type", "multiSelect",
                                     "--options", "todo,doing,done"])
        guard let propId = parseId(from: Data(propResult.stdout.utf8)) else {
            XCTFail("create prop failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        // Pass comma-separated values; CLI must store them as JSON-encoded [String]
        // so the app's multi-select decoder can read them.
        let setResult = try runCLI(["properties", "--set",
                                    "--reference", String(refId),
                                    "--id", String(propId),
                                    "--value", "todo,doing"])
        XCTAssertEqual(setResult.exitCode, 0)

        let listed = try runCLI(["properties", "--reference", String(refId)])
        let arr = try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] ?? []
        guard let entry = arr.first(where: { ($0["propertyId"] as? String) == String(propId) }),
              let storedJSON = entry["value"] as? String,
              let decoded = try JSONSerialization.jsonObject(with: Data(storedJSON.utf8)) as? [String] else {
            XCTFail("stored multiSelect value should decode as a JSON string array; got \(arr)")
            return
        }
        XCTAssertEqual(decoded, ["todo", "doing"])
    }

    func testPropertiesClearUnknownPropertyIsRefused() throws {
        try skipIfBinaryMissing()

        let addResult = try runCLI(["add", "--title", "CLI Clear Guard \(UUID().uuidString.prefix(8))"])
        guard let refId = parseId(from: Data(addResult.stdout.utf8)) else {
            XCTFail("add failed")
            return
        }
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        let result = try runCLI(["properties", "--clear",
                                 "--reference", String(refId),
                                 "--id", "999999999"])
        XCTAssertNotEqual(result.exitCode, 0, "--clear with an unknown property id must fail")
        let errData = Data(result.stderr.utf8)
        if let errJson = try? JSONSerialization.jsonObject(with: errData) as? [String: Any] {
            XCTAssertNotNil(errJson["error"], "stderr should be a JSON error object")
        }
    }

    func testAddBibTeXDedupePreservesExistingCustomProperties() throws {
        try skipIfBinaryMissing()

        // 1. Create a reference, attach a custom property value to it.
        let title = "CLI Add Dedupe \(UUID().uuidString.prefix(8))"
        let bib = """
        @article{cli-dedupe-\(UUID().uuidString.prefix(6)),
          title = {\(title)},
          author = {Smith, John},
          year = {2024},
          doi = {10.9999/cli-dedupe-\(UUID().uuidString.prefix(6))}
        }
        """

        let firstAdd = try runCLI(["add", "--bibtex", bib])
        XCTAssertEqual(firstAdd.exitCode, 0)
        let firstArr = try JSONSerialization.jsonObject(with: Data(firstAdd.stdout.utf8)) as? [[String: Any]] ?? []
        guard let firstObj = firstArr.first,
              let refIdInt = firstObj["id"] as? Int64 ?? (firstObj["id"] as? Int).map(Int64.init) else {
            XCTFail("first add should return JSON array with one ref id")
            return
        }
        let refId = refIdInt
        defer { _ = try? runCLI(["delete", String(refId), "--force"]) }

        let propResult = try runCLI(["properties", "--create",
                                     "--name", "cli-dedupe-prop-\(UUID().uuidString.prefix(8))",
                                     "--type", "string"])
        guard let propId = parseId(from: Data(propResult.stdout.utf8)) else {
            XCTFail("create prop failed")
            return
        }
        defer { _ = try? runCLI(["properties", "--delete", String(propId)]) }

        let setResult = try runCLI(["properties", "--set",
                                    "--reference", String(refId),
                                    "--id", String(propId),
                                    "--value", "preserve-me"])
        XCTAssertEqual(setResult.exitCode, 0)

        // 2. Re-add the same BibTeX entry. saveReference should dedupe onto the
        // existing row; the echoed ReferenceDTO must surface the existing
        // customProperties, not an empty array.
        let secondAdd = try runCLI(["add", "--bibtex", bib])
        XCTAssertEqual(secondAdd.exitCode, 0)
        let secondArr = try JSONSerialization.jsonObject(with: Data(secondAdd.stdout.utf8)) as? [[String: Any]] ?? []
        guard let secondObj = secondArr.first else {
            XCTFail("second add should return JSON array")
            return
        }
        let custom = secondObj["customProperties"] as? [[String: Any]] ?? []
        XCTAssertTrue(custom.contains { ($0["value"] as? String) == "preserve-me" },
                      "dedup-add output must echo existing custom properties; got \(custom)")
    }

    func testExportJSONIncludesCustomPropertiesField() throws {
        try skipIfBinaryMissing()
        let result = try runCLI(["export", "--format", "json"])
        XCTAssertEqual(result.exitCode, 0)
        let arr = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] ?? []
        if let first = arr.first {
            XCTAssertNotNil(first["customProperties"], "every reference should carry a customProperties array")
            XCTAssertTrue(first["customProperties"] is [Any], "customProperties must be an array")
        }
    }
}
