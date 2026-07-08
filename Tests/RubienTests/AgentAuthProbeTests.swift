#if os(macOS)
import XCTest

@testable import Rubien

final class AgentAuthProbeTests: XCTestCase {
    func testClaudeSignedInJSONParsesAuthenticated() {
        let status = AgentAuthProbe.claudeStatus(from: commandResult(
            exitCode: 0,
            stdout: #"{"loggedIn":true,"email":"person@example.com"}"#))

        XCTAssertEqual(status, .authenticated)
    }

    func testClaudeSignedOutJSONParsesUnauthenticated() {
        let status = AgentAuthProbe.claudeStatus(from: commandResult(
            exitCode: 1,
            stdout: #"{"loggedIn":false,"authMethod":"none"}"#))

        XCTAssertEqual(status, .unauthenticated)
    }

    func testClaudeUnknownOutputFailsOpen() {
        let status = AgentAuthProbe.claudeStatus(from: commandResult(
            exitCode: 0,
            stdout: "Claude Code 2.1.204"))

        XCTAssertEqual(status, .unknown)
    }

    func testCodexSignedInTextParsesAuthenticated() {
        let status = AgentAuthProbe.codexStatus(from: commandResult(
            exitCode: 0,
            stdout: "Logged in using ChatGPT\n"))

        XCTAssertEqual(status, .authenticated)
    }

    func testCodexSignedOutTextParsesUnauthenticated() {
        let status = AgentAuthProbe.codexStatus(from: commandResult(
            exitCode: 1,
            stdout: "Not logged in. Run codex login to authenticate.\n"))

        XCTAssertEqual(status, .unauthenticated)
    }

    func testCodexSignedOutTextWinsOverLoggedInSubstring() {
        let status = AgentAuthProbe.codexStatus(from: commandResult(
            exitCode: 0,
            stdout: "Not logged in. Run codex login to authenticate.\n"))

        XCTAssertEqual(status, .unauthenticated)
    }

    func testCodexUnknownOutputFailsOpen() {
        let status = AgentAuthProbe.codexStatus(from: commandResult(
            exitCode: 0,
            stdout: "Codex account status changed shape"))

        XCTAssertEqual(status, .unknown)
    }

    private func commandResult(
        exitCode: Int32,
        stdout: String,
        stderr: String = "",
        timedOut: Bool = false
    ) -> AgentBinaryProbe.CommandResult {
        AgentBinaryProbe.CommandResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            timedOut: timedOut)
    }
}
#endif
