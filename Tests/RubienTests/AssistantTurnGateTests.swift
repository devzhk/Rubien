#if os(macOS)
import XCTest

@testable import Rubien

/// Tests for `AssistantTurnGate` — per-session serialization for both providers.
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

    func testNewClaudeConversationsAreUnkeyedAndAlwaysAdmitted() async {
        let gate = AssistantTurnGate()
        // A brand-new conversation has no session id yet → never blocks another.
        let a = await gate.tryAcquire(provider: .claude, sessionID: nil)
        let b = await gate.tryAcquire(provider: .claude, sessionID: nil)
        let c = await gate.tryAcquire(provider: .claude, sessionID: "")
        XCTAssertTrue(a)
        XCTAssertTrue(b)
        XCTAssertTrue(c)
    }

    func testCodexSerializesOnlyTheSameResumedSession() async {
        let gate = AssistantTurnGate()
        let fresh = await gate.tryAcquire(provider: .codex, sessionID: nil)
        let otherFresh = await gate.tryAcquire(provider: .codex, sessionID: nil)
        let resumed = await gate.tryAcquire(provider: .codex, sessionID: "thread-1")
        let otherResumed = await gate.tryAcquire(provider: .codex, sessionID: "thread-2")
        let duplicate = await gate.tryAcquire(provider: .codex, sessionID: "thread-1")

        XCTAssertTrue(fresh)
        XCTAssertTrue(otherFresh)
        XCTAssertTrue(resumed)
        XCTAssertTrue(otherResumed)
        XCTAssertFalse(duplicate)
        let busy = await gate.isBusy(provider: .codex, sessionID: "thread-1")
        XCTAssertTrue(busy)

        await gate.release(provider: .codex, sessionID: "thread-1")
        let reacquired = await gate.tryAcquire(provider: .codex, sessionID: "thread-1")
        XCTAssertTrue(reacquired)
    }

    func testDifferentProviderOrSessionAreIndependent() async {
        let gate = AssistantTurnGate()
        let claudeS = await gate.tryAcquire(provider: .claude, sessionID: "s")
        // Same session id, different provider → independent slot.
        let codexS = await gate.tryAcquire(provider: .codex, sessionID: "s")
        // Claude keeps per-session slots.
        let claudeOther = await gate.tryAcquire(provider: .claude, sessionID: "other")
        // Codex also keeps per-session slots.
        let codexOther = await gate.tryAcquire(provider: .codex, sessionID: "other")
        // But the original is still held.
        let claudeSAgain = await gate.tryAcquire(provider: .claude, sessionID: "s")
        XCTAssertTrue(claudeS)
        XCTAssertTrue(codexS)
        XCTAssertTrue(claudeOther)
        XCTAssertTrue(codexOther)
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
#endif
