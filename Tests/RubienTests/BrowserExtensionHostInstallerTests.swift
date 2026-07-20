#if os(macOS)
import XCTest
@testable import Rubien
import RubienCore

final class BrowserExtensionHostInstallerTests: XCTestCase {
    func testInstallsManifestForExecutableBundledHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienBrowserHostInstallerTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appendingPathComponent("Rubien.app", isDirectory: true)
        let helperURL = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("rubien-browser-host")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: helperURL.path,
            contents: Data("#!/bin/sh\n".utf8)
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let supportURL = root.appendingPathComponent("Application Support", isDirectory: true)
        let manifestURL = try XCTUnwrap(try BrowserExtensionHostInstaller.install(
            bundleURL: bundleURL,
            applicationSupportURL: supportURL
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )

        XCTAssertEqual(object["name"] as? String, BrowserClipContract.nativeHostName)
        XCTAssertEqual(object["path"] as? String, helperURL.standardizedFileURL.path)
        XCTAssertEqual(object["type"] as? String, "stdio")
        XCTAssertEqual(
            object["allowed_origins"] as? [String],
            [BrowserClipContract.allowedExtensionOrigin]
        )

        let firstData = try Data(contentsOf: manifestURL)
        XCTAssertEqual(
            try BrowserExtensionHostInstaller.install(
                bundleURL: bundleURL,
                applicationSupportURL: supportURL
            ),
            manifestURL
        )
        XCTAssertEqual(try Data(contentsOf: manifestURL), firstData)
    }

    func testSkipsNonAppBundleAndMissingHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienBrowserHostInstallerTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(try BrowserExtensionHostInstaller.install(
            bundleURL: root.appendingPathComponent("debug"),
            applicationSupportURL: root
        ))
        XCTAssertNil(try BrowserExtensionHostInstaller.install(
            bundleURL: root.appendingPathComponent("Rubien.app"),
            applicationSupportURL: root
        ))
    }
}
#endif
