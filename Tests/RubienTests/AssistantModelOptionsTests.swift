#if os(macOS)
import XCTest
@testable import Rubien

/// Locks in the per-backend descriptor guarantees (Phase 3b-3): the seed default is
/// always a value the backend actually offers (so a fresh conversation never starts
/// on an unselectable/unaccepted slug), and normalization snaps stale/foreign values
/// back onto the list.
final class AssistantModelOptionsTests: XCTestCase {

    /// The co-location invariant the descriptor exists to protect: each backend's
    /// default model/effort MUST appear in that backend's own list. A drift here is
    /// exactly the bug the single-descriptor design prevents.
    func testEveryBackendDefaultIsInItsOwnList() {
        for kind in AgentProviderKind.allCases {
            let models = AssistantModelOptions.models(for: kind).map(\.value)
            let efforts = AssistantModelOptions.efforts(for: kind).map(\.value)
            XCTAssertTrue(models.contains(AssistantModelOptions.defaultModel(for: kind)),
                          "\(kind) default model must be one of its listed models")
            XCTAssertTrue(efforts.contains(AssistantModelOptions.defaultEffort(for: kind)),
                          "\(kind) default effort must be one of its listed efforts")
        }
    }

    func testBackendListsAreDistinctAndSlugsVerified() {
        // Claude and Codex accept disjoint model slugs; guard against copy-paste.
        XCTAssertEqual(AssistantModelOptions.models(for: .claude).map(\.value), ["fable", "opus", "sonnet"])
        XCTAssertEqual(AssistantModelOptions.models(for: .codex).map(\.value), ["gpt-5.5", "gpt-5.5-pro"])
        // Codex has no `max` effort; Claude does.
        XCTAssertTrue(AssistantModelOptions.efforts(for: .claude).map(\.value).contains("max"))
        XCTAssertFalse(AssistantModelOptions.efforts(for: .codex).map(\.value).contains("max"))
    }

    func testNormalizationSnapsForeignOrStaleValuesToDefault() {
        // Valid values pass through untouched.
        XCTAssertEqual(AssistantModelOptions.normalizedModel("sonnet", for: .claude), "sonnet")
        XCTAssertEqual(AssistantModelOptions.normalizedEffort("xhigh", for: .codex), "xhigh")
        // Foreign / empty / unknown values snap to the backend default.
        XCTAssertEqual(AssistantModelOptions.normalizedModel("gpt-5.5", for: .claude), "opus")
        XCTAssertEqual(AssistantModelOptions.normalizedModel("", for: .codex), "gpt-5.5")
        XCTAssertEqual(AssistantModelOptions.normalizedEffort("max", for: .codex), "medium")
        XCTAssertEqual(AssistantModelOptions.normalizedEffort("bogus", for: .claude), "high")
    }

    func testDescriptorMetadata() {
        XCTAssertEqual(AgentProviderKind.claude.displayName, "Claude")
        XCTAssertEqual(AgentProviderKind.codex.displayName, "Codex")
        XCTAssertFalse(AgentProviderKind.claude.descriptor.supportsSandbox)
        XCTAssertTrue(AgentProviderKind.codex.descriptor.supportsSandbox)
    }
}
#endif
