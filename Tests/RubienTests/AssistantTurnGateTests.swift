import XCTest

@testable import Rubien

/// Tests for `AssistantTurnGate` — the per-`(provider, sessionID)` serialization
/// that prevents two windows from forking a resumed session (§4.1).
final class AssistantTurnGateTests: XCTestCase {

    func testKeyedSessionIsExclusiveThenReusableAfterRelease() async {
        let gate = AssistantTurnGate()
        // First claim on a resumed session succeeds…
        let first = await gate.tryAcquire(provider: .claude, sessionID: "sess-1")
        XCTAssertTrue(first)
        // …a second overlapping claim is refused (busy in another window)…
        let second = await gate.tryAcquire(provider: .claude, sessionID: "sess-1")
        XCTAssertFalse(second)
        let busy = await gate.isBusy(provider: .claude, sessionID: "sess-1")
        XCTAssertTrue(busy)
        // …and after release it is claimable again.
        await gate.release(provider: .claude, sessionID: "sess-1")
        let third = await gate.tryAcquire(provider: .claude, sessionID: "sess-1")
        XCTAssertTrue(third)
    }

    func testNewConversationsAreUnkeyedAndAlwaysAdmitted() async {
        let gate = AssistantTurnGate()
        // A brand-new conversation has no session id yet → never blocks another.
        let a = await gate.tryAcquire(provider: .claude, sessionID: nil)
        let b = await gate.tryAcquire(provider: .claude, sessionID: nil)
        let c = await gate.tryAcquire(provider: .claude, sessionID: "")
        XCTAssertTrue(a)
        XCTAssertTrue(b)
        XCTAssertTrue(c)
    }

    func testDifferentProviderOrSessionAreIndependent() async {
        let gate = AssistantTurnGate()
        let claudeS = await gate.tryAcquire(provider: .claude, sessionID: "s")
        // Same session id, different provider → independent slot.
        let codexS = await gate.tryAcquire(provider: .codex, sessionID: "s")
        // Same provider, different session id → independent slot.
        let claudeOther = await gate.tryAcquire(provider: .claude, sessionID: "other")
        // But the original is still held.
        let claudeSAgain = await gate.tryAcquire(provider: .claude, sessionID: "s")
        XCTAssertTrue(claudeS)
        XCTAssertTrue(codexS)
        XCTAssertTrue(claudeOther)
        XCTAssertFalse(claudeSAgain)
    }

    func testReleaseOfUnheldOrNilKeyIsHarmless() async {
        let gate = AssistantTurnGate()
        await gate.release(provider: .claude, sessionID: nil)
        await gate.release(provider: .claude, sessionID: "never-held")
        let busy = await gate.isBusy(provider: .claude, sessionID: "never-held")
        XCTAssertFalse(busy)
    }
}
