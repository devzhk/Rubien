#if os(macOS)
import XCTest
@testable import Rubien

final class ProviderUpdateTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-update-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testSemVerPrecedenceAndBuildMetadata() throws {
        let values = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                      "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.9", "1.0.10", "2.0.0"]
        let versions = try values.map { try XCTUnwrap(ProviderReleaseVersion($0)) }
        XCTAssertEqual(versions.sorted(), versions)
        for pair in zip(versions, versions.dropFirst()) { XCTAssertLessThan(pair.0, pair.1) }
        XCTAssertEqual(ProviderReleaseVersion("1.0.0+build.5"), ProviderReleaseVersion("1.0.0+build.8"))
        XCTAssertLessThan(try XCTUnwrap(ProviderReleaseVersion("1.0.0-99999999999999999999")),
                          try XCTUnwrap(ProviderReleaseVersion("1.0.0-100000000000000000000")))
    }

    func testRejectsUnknownAndMalformedVersions() {
        for value in ["latest", "1.2", "v1.2.3", "01.2.3", "1.2.3-01", "1.2.3-", "1.2.3+a..b",
                      "1.2.3\n", "1.2.3-beta\n", "codex-cli 1.2.3", "1.2.3.4", "9999999999999999999999999.2.3"] {
            XCTAssertNil(ProviderReleaseVersion(value), value)
        }
    }

    func testDecodesVerifiedDistributionShapesAndRejectsOtherPackages() throws {
        let fixtures: [(ProviderReleaseSource, String, String)] = [
            (.codexNative, #"{"tag_name":"rust-v0.160.0","assets":[]}"#, "0.160.0"),
            (.claudeNative, "2.1.288\n", "2.1.288"),
            (.codexNPM, #"{"name":"@openai/codex","version":"0.160.0"}"#, "0.160.0"),
            (.claudeNPM, #"{"name":"@anthropic-ai/claude-code","version":"2.1.288"}"#, "2.1.288"),
            (.codexHomebrew, #"{"token":"codex","tap":"homebrew/cask","version":"0.160.0"}"#, "0.160.0"),
            (.claudeHomebrew, #"{"token":"claude-code","tap":"homebrew/cask","version":"2.1.285"}"#, "2.1.285")
        ]
        for (source, fixture, version) in fixtures { XCTAssertEqual(try source.decode(Data(fixture.utf8)).rawValue, version) }
        for value in [#"{"name":"other","version":"1.2.3"}"#, #"{"name":"@openai/codex","version":"1.2.3-beta.1"}"#,
                      #"{"name":"@openai/codex","version":123}"#, "<html>Error</html>"] {
            XCTAssertThrowsError(try ProviderReleaseSource.codexNPM.decode(Data(value.utf8)))
        }
        XCTAssertThrowsError(try ProviderReleaseSource.codexHomebrew.decode(Data(#"{"token":"codex","tap":"third-party/cask","version":"1.2.3"}"#.utf8)))
        XCTAssertThrowsError(try ProviderReleaseSource.codexNative.decode(Data(#"{"tag_name":"rust-v1.2.3","draft":true}"#.utf8)))
        XCTAssertThrowsError(try ProviderReleaseSource.claudeNative.decode(Data(repeating: 65, count: ProviderReleaseClient.maximumBytes + 1)))
    }

    func testResponseValidationAndRetryAfter() throws {
        let source = ProviderReleaseSource.codexNPM
        let now = Date(timeIntervalSince1970: 0)
        func response(_ code: Int, _ headers: [String: String] = [:], url: URL? = nil) -> HTTPURLResponse {
            HTTPURLResponse(url: url ?? source.url, statusCode: code, httpVersion: nil, headerFields: headers)!
        }
        XCTAssertNoThrow(try ProviderReleaseClient.validateResponse(response(200), source: source, now: now))
        for code in [301, 302, 403, 404, 500] {
            XCTAssertThrowsError(try ProviderReleaseClient.validateResponse(response(code), source: source, now: now))
        }
        XCTAssertThrowsError(try ProviderReleaseClient.validateResponse(response(200, url: URL(string: "https://example.com/latest")!), source: source, now: now))
        XCTAssertThrowsError(try ProviderReleaseClient.validateResponse(response(200, ["Content-Length": "9999999"]), source: source, now: now))
        XCTAssertThrowsError(try ProviderReleaseClient.validateResponse(response(429, ["Retry-After": "600"]), source: source, now: now)) { error in
            guard case ProviderReleaseError.rateLimited(let date) = error else { return XCTFail("Missing rate limit") }
            XCTAssertEqual(date, now.addingTimeInterval(600))
        }
        XCTAssertEqual(ProviderReleaseClient.retryDate("Thu, 01 Jan 1970 01:00:00 GMT", now: now), now.addingTimeInterval(3600))
        XCTAssertNil(ProviderReleaseClient.retryDate("nan", now: now))
    }

    func testScheduleBackoffManualRetryAndOptOut() {
        let now = Date()
        var record = ProviderUpdateRecord()
        XCTAssertTrue(record.shouldCheck(manual: false, now: now))
        record.failed(message: "Offline", now: now, retryAfter: nil)
        XCTAssertEqual(record.nextCheckAt, now.addingTimeInterval(3600))
        XCTAssertFalse(record.shouldCheck(manual: false, now: now))
        XCTAssertTrue(record.shouldCheck(manual: true, now: now))
        record.failed(message: "Offline", now: now, retryAfter: nil)
        XCTAssertEqual(record.nextCheckAt, now.addingTimeInterval(21600))
        record.failed(message: "Limited", now: now, retryAfter: now.addingTimeInterval(100))
        XCTAssertFalse(record.shouldCheck(manual: true, now: now))
        XCTAssertEqual(record.nextCheckAt, now.addingTimeInterval(86400))
        record.automaticChecks = false
        XCTAssertFalse(record.shouldCheck(manual: false, now: now.addingTimeInterval(90000)))
        XCTAssertTrue(record.shouldCheck(manual: true, now: now.addingTimeInterval(90000)))
    }

    @MainActor
    func testNewReleaseIsShownAndDailyChecksAreMemoized() async throws {
        let counter = ReleaseTestCounter()
        let clock = ProviderSetupTestClock()
        let model = try model(counter: counter, clock: clock)
        await model.check()
        XCTAssertEqual(model.record.snapshot?.availableVersion, "0.160.0")
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(model.record.nextCheckAt, clock.now().addingTimeInterval(86400))
        await model.check()
        var calls = await counter.count
        XCTAssertEqual(calls, 1)
        clock.advance(86401)
        await model.check()
        calls = await counter.count
        XCTAssertEqual(calls, 2)
        await model.check(manual: true)
        calls = await counter.count
        XCTAssertEqual(calls, 3)
    }

    @MainActor
    func testOptOutIsSharedAndManualCheckDoesNotNotify() async throws {
        let counter = ReleaseTestCounter()
        let first = try model(counter: counter)
        await first.check()
        first.setAutomaticChecks(false)
        XCTAssertNil(first.notice)
        let second = try model(counter: counter, createExecutable: false)
        await second.check()
        XCTAssertFalse(second.record.automaticChecks)
        var calls = await counter.count
        XCTAssertEqual(calls, 1)
        await second.check(manual: true)
        calls = await counter.count
        XCTAssertEqual(calls, 2)
        XCTAssertNil(second.notice)
        XCTAssertEqual(second.record.snapshot?.availableVersion, "0.160.0")
    }

    @MainActor
    func testLaterPersistsForSevenDaysAndNewVersionCanNotify() async throws {
        let clock = ProviderSetupTestClock()
        let counter = ReleaseTestCounter()
        let first = try model(counter: counter, clock: clock)
        await first.check()
        first.later()
        XCTAssertNil(first.notice)
        let second = try model(counter: counter, clock: clock, createExecutable: false)
        await second.check(manual: true)
        XCTAssertNil(second.notice)
        await counter.setVersion("0.161.0")
        await second.check(manual: true)
        XCTAssertEqual(second.notice?.availableVersion, "0.161.0")
        second.later()
        clock.advance(7 * 86400 + 1)
        let third = try model(counter: counter, clock: clock, createExecutable: false)
        await third.check()
        XCTAssertNotNil(third.notice)
        third.dismissNotice()
        await third.check(manual: true)
        XCTAssertNil(third.notice, "One notice per installation/version in this process")
    }

    @MainActor
    func testFailurePreservesTimestampButSuppressesStaleNotice() async throws {
        let counter = ReleaseTestCounter()
        let model = try model(counter: counter)
        await model.check()
        let successful = model.record.snapshot
        await counter.setFailure(true)
        await model.check(manual: true)
        XCTAssertEqual(model.record.snapshot, successful)
        XCTAssertNotNil(model.record.lastError)
        XCTAssertNil(model.notice)
        await model.check()
        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testNativePolicyUnknownAndNewerInstalledVersionNeverNotify() async throws {
        let counter = ReleaseTestCounter()
        let native = try model(counter: counter, hint: .native)
        await native.check()
        XCTAssertTrue(native.record.snapshot?.hasNewerRelease == true)
        XCTAssertNil(native.notice)
        let newer = try model(counter: counter, installed: "0.170.0", createExecutable: false)
        await newer.check(manual: true)
        XCTAssertFalse(newer.record.snapshot?.hasNewerRelease == true)
        XCTAssertNil(newer.notice)
    }

    @MainActor
    func testPrereleaseUnknownAndMissingInstallationsNeverFetch() async throws {
        let counter = ReleaseTestCounter()
        let prerelease = try model(counter: counter, installed: "0.170.0-alpha.1")
        await prerelease.check()
        XCTAssertNil(prerelease.record.snapshot)
        XCTAssertNotNil(prerelease.detail)
        let unknown = try model(counter: counter, hint: .unknown, createExecutable: false)
        await unknown.check()
        XCTAssertNotNil(unknown.detail)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("codex"))
        await unknown.check()
        XCTAssertNil(unknown.record.snapshot)
        XCTAssertNil(unknown.notice)
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testBinaryReplacementInvalidatesCachedResultBeforeNextDailyCheck() async throws {
        let counter = ReleaseTestCounter()
        let model = try model(counter: counter)
        await model.check()
        let before = model.record.snapshot?.fingerprint
        try Data("replacement".utf8).write(to: directory.appendingPathComponent("codex"), options: .atomic)
        await model.check()
        XCTAssertNotEqual(model.record.snapshot?.fingerprint, before)
        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testInFlightCheckDeduplicatesAndDiscardsReplacedExecutable() async throws {
        let started = expectation(description: "fetch started")
        let gate = ReleaseTestGate()
        let path = directory.appendingPathComponent("codex")
        try Data("initial".utf8).write(to: path)
        let store = ProviderUpdateStore(root: directory.appendingPathComponent("state"))
        let found = ProviderInstallation(state: .found, path: path.path, hint: .npm, detail: nil)
        let model = ProviderUpdateModel(provider: .codex, store: store, override: { nil },
            discover: { _, _ in found }, version: { _, _ in "0.153.4" }, fetch: { _ in
                started.fulfill()
                await gate.wait()
                return ProviderReleaseVersion("0.160.0")!
            })
        let task = Task { await model.check() }
        await fulfillment(of: [started], timeout: 2)
        await model.check(manual: true)
        XCTAssertTrue(model.isChecking)
        let second = ProviderUpdateModel(provider: .codex, store: store, override: { nil },
            discover: { _, _ in found }, version: { _, _ in XCTFail("Lock must prevent second probe"); return nil },
            fetch: { _ in XCTFail("Lock must prevent second request"); return ProviderReleaseVersion("1.0.0")! })
        await second.check(manual: true)
        XCTAssertNotNil(second.detail)
        try Data("changed while fetching".utf8).write(to: path, options: .atomic)
        await gate.release()
        await task.value
        XCTAssertNil(model.record.snapshot)
        XCTAssertNil(model.notice)
        XCTAssertNil(store.read(ProviderUpdateStore.key(provider: .codex, path: path.path)).snapshot)
    }

    @MainActor
    func testChangingSelectedPathDiscardsOldResponseAndChecksNewSelection() async throws {
        let started = expectation(description: "first request started")
        let gate = ReleaseTestGate()
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        var selected = first.path
        let store = ProviderUpdateStore(root: directory.appendingPathComponent("state"))
        let counter = ReleaseTestCounter()
        let model = ProviderUpdateModel(provider: .codex, store: store, override: { selected },
            discover: { _, path in .init(state: .found, path: path, hint: .npm, detail: nil) },
            version: { _, path in path == first.path ? "0.153.4" : "0.160.0" }, fetch: { _ in
                let result = try await counter.fetch()
                if await counter.count == 1 {
                    started.fulfill()
                    await gate.wait()
                }
                return result
            })
        let oldCheck = Task { await model.check() }
        await fulfillment(of: [started], timeout: 2)
        selected = second.path
        await gate.release()
        await oldCheck.value
        XCTAssertNil(model.record.snapshot)
        XCTAssertNil(store.read(ProviderUpdateStore.key(provider: .codex, path: first.path)).snapshot)
        await model.check()
        XCTAssertEqual(model.record.snapshot?.installedVersion, "0.160.0")
        XCTAssertFalse(model.record.snapshot?.hasNewerRelease == true)
        XCTAssertNil(model.notice)
    }

    @MainActor
    func testOptOutDuringFetchSurvivesResultPersistence() async throws {
        let started = expectation(description: "request started")
        let gate = ReleaseTestGate()
        let path = directory.appendingPathComponent("codex")
        try Data("fixture".utf8).write(to: path)
        let model = ProviderUpdateModel(provider: .codex,
            store: ProviderUpdateStore(root: directory.appendingPathComponent("state")), override: { nil },
            discover: { _, _ in .init(state: .found, path: path.path, hint: .npm, detail: nil) },
            version: { _, _ in "0.153.4" }, fetch: { _ in
                started.fulfill()
                await gate.wait()
                return ProviderReleaseVersion("0.160.0")!
            })
        let check = Task { await model.check() }
        await fulfillment(of: [started], timeout: 2)
        model.setAutomaticChecks(false)
        await gate.release()
        await check.value
        XCTAssertFalse(model.record.automaticChecks)
        XCTAssertNotNil(model.record.snapshot)
        XCTAssertNil(model.notice)
    }

    @MainActor
    private func model(counter: ReleaseTestCounter, clock: ProviderSetupTestClock = .init(),
                       hint: ProviderInstallation.MethodHint = .npm, installed: String = "0.153.4",
                       createExecutable: Bool = true) throws -> ProviderUpdateModel {
        let path = directory.appendingPathComponent("codex")
        if createExecutable { try Data("fixture".utf8).write(to: path) }
        let found = ProviderInstallation(state: .found, path: path.path, hint: hint, detail: nil)
        return ProviderUpdateModel(provider: .codex, store: ProviderUpdateStore(root: directory.appendingPathComponent("state")),
            override: { nil }, now: { clock.now() }, jitter: { 0 }, discover: { _, _ in found },
            version: { _, _ in installed }, fetch: { _ in try await counter.fetch() })
    }

    func testLiveMetadataContractsWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUBIEN_PROVIDER_UPDATE_LIVE"] == "1" else {
            throw XCTSkip("Opt in to read-only public release metadata checks")
        }
        for source in [ProviderReleaseSource.codexNative, .claudeNative, .codexNPM, .claudeNPM, .codexHomebrew, .claudeHomebrew] {
            let version = try await ProviderReleaseClient.fetch(source)
            print("Live release metadata \(source.rawValue): \(version.rawValue)")
        }
    }
}

private actor ReleaseTestCounter {
    var count = 0
    var version = "0.160.0"
    var failure = false
    func setVersion(_ value: String) { version = value }
    func setFailure(_ value: Bool) { failure = value }
    func fetch() throws -> ProviderReleaseVersion {
        count += 1
        if failure { throw URLError(.notConnectedToInternet) }
        return ProviderReleaseVersion(version)!
    }
}

private actor ReleaseTestGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
