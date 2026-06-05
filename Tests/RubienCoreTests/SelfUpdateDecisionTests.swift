import XCTest
@testable import RubienCore

final class SelfUpdateDecisionTests: XCTestCase {
    private func release(_ tag: String, _ assets: [(String, String)]) -> GitHubRelease {
        GitHubRelease(tagName: tag, assets: assets.map {
            GitHubRelease.Asset(name: $0.0, browserDownloadUrl: URL(string: $0.1)!)
        })
    }

    func testSemverGreater() {
        XCTAssertTrue(semverGreater("0.1.8", "0.1.7"))
        XCTAssertTrue(semverGreater("0.2.0", "0.1.9"))
        XCTAssertFalse(semverGreater("0.1.7", "0.1.7"))
        XCTAssertFalse(semverGreater("0.1.6", "0.1.7"))
    }

    func testIsPlainNumeric() {
        XCTAssertTrue(isPlainNumeric("0.1.8"))
        XCTAssertTrue(isPlainNumeric("12"))
        XCTAssertFalse(isPlainNumeric("0.1.8-beta"))
        XCTAssertFalse(isPlainNumeric("1..2"))
        XCTAssertFalse(isPlainNumeric("1."))
        XCTAssertFalse(isPlainNumeric(".1"))
        XCTAssertFalse(isPlainNumeric(""))
    }

    func testUpToDateWhenNotNewer() {
        XCTAssertEqual(decideUpdate(currentMarketing: "0.1.7", release: release("v0.1.7", [])),
                       .upToDate(current: "0.1.7", latest: "0.1.7"))
    }

    func testUpdateAvailableWithTarballAndSig() {
        let r = release("v0.1.8", [
            ("rubien-cli-v0.1.8-linux-x86_64.tar.gz", "https://x/t.tgz"),
            ("rubien-cli-v0.1.8-linux-x86_64.tar.gz.sig", "https://x/t.tgz.sig"),
        ])
        XCTAssertEqual(decideUpdate(currentMarketing: "0.1.7", release: r),
                       .updateAvailable(latest: "0.1.8",
                                        tarball: URL(string: "https://x/t.tgz")!,
                                        signature: URL(string: "https://x/t.tgz.sig")!))
    }

    func testNoAssetWhenSigMissing() {
        let r = release("v0.1.8", [("rubien-cli-v0.1.8-linux-x86_64.tar.gz", "https://x/t.tgz")])
        XCTAssertEqual(decideUpdate(currentMarketing: "0.1.7", release: r), .noAsset(latest: "0.1.8"))
    }

    func testNonNumericTagIgnored() {
        let r = release("v0.1.8-beta", [
            ("rubien-cli-v0.1.8-beta-linux-x86_64.tar.gz", "https://x/t.tgz"),
            ("rubien-cli-v0.1.8-beta-linux-x86_64.tar.gz.sig", "https://x/t.tgz.sig"),
        ])
        XCTAssertEqual(decideUpdate(currentMarketing: "0.1.7", release: r),
                       .upToDate(current: "0.1.7", latest: "0.1.8-beta"))
    }
}
