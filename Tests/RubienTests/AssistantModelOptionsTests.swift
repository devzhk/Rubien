#if os(macOS)
import XCTest
@testable import Rubien

/// Locks in the per-backend descriptor guarantees (Phase 3b-3): the seed default is
/// always a value the backend actually offers (so a fresh conversation never starts
/// on an unselectable/unaccepted slug), and normalization snaps stale/foreign values
/// back onto the list.
final class AssistantModelOptionsTests: XCTestCase {

    /// Claude keeps the static co-location invariant. Codex's static model list is
    /// GONE (discovery-fed, spec §4.8) — only its fallback efforts remain static.
    func testClaudeDefaultsAreInItsOwnLists() {
        let models = AssistantModelOptions.models(for: .claude).map(\.value)
        let efforts = AssistantModelOptions.efforts(for: .claude).map(\.value)
        XCTAssertEqual(AssistantModelOptions.defaultModel(for: .claude), "opus")
        XCTAssertTrue(models.contains("opus"))
        XCTAssertTrue(efforts.contains(AssistantModelOptions.defaultEffort(for: .claude)))
    }

    func testCodexDescriptorIsDiscoveryFed() {
        XCTAssertEqual(AssistantModelOptions.models(for: .claude).map(\.value), ["fable", "opus", "sonnet"])
        XCTAssertTrue(AssistantModelOptions.models(for: .codex).isEmpty,
                      "Codex models come from the live catalog, never a baked list (spec §4.6/§4.7)")
        XCTAssertNil(AssistantModelOptions.defaultModel(for: .codex),
                     "no static default — nil pick means 'send no model' (Codex default)")
        // The universal fallback four (catalog-less effort picker only).
        XCTAssertEqual(AssistantModelOptions.efforts(for: .codex).map(\.value),
                       ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(AssistantModelOptions.defaultEffort(for: .codex), "medium")
    }

    /// Claude normalization is unchanged; Codex values PASS THROUGH (no static list
    /// to normalize against — validity is the catalog-aware picker's job).
    func testNormalizationClaudeOnlyCodexPassesThrough() {
        XCTAssertEqual(AssistantModelOptions.normalizedModel("sonnet", for: .claude), "sonnet")
        XCTAssertEqual(AssistantModelOptions.normalizedModel("gpt-5.5", for: .claude), "opus")
        XCTAssertEqual(AssistantModelOptions.normalizedModel("anything", for: .codex), "anything")
        XCTAssertEqual(AssistantModelOptions.normalizedEffort("bogus", for: .claude), "high")
        XCTAssertEqual(AssistantModelOptions.normalizedEffort("ultra", for: .codex), "ultra",
                       "no static clamp — ultra is valid on 5.6 models")
    }

    func testDescriptorMetadata() {
        XCTAssertEqual(AgentProviderKind.claude.displayName, "Claude")
        XCTAssertEqual(AgentProviderKind.codex.displayName, "Codex")
        XCTAssertFalse(AgentProviderKind.claude.descriptor.supportsSandbox)
        XCTAssertTrue(AgentProviderKind.codex.descriptor.supportsSandbox)
    }

    // MARK: Shared picker row builders (sidebar + Settings consume the same logic)

    private let terra = CodexModelInfo(
        id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", description: "Balanced.",
        efforts: [CodexEffortInfo(value: "low", label: "Low", description: nil),
                  CodexEffortInfo(value: "ultra", label: "Ultra", description: nil)],
        defaultEffort: "medium", isDefault: false, hidden: false)
    private let sol = CodexModelInfo(
        id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", description: nil,
        efforts: [], defaultEffort: "low", isDefault: true, hidden: false)

    func testCodexModelRowsDefaultFirstThenCatalog() {
        let rows = AssistantModelOptions.codexModelRows(models: [terra, sol], pinned: nil, resolvedModel: nil)
        XCTAssertEqual(rows.map(\.value), [nil, "gpt-5.6-terra", "gpt-5.6-sol"])
        XCTAssertEqual(rows[0].label, "Codex default")
        XCTAssertEqual(rows[1].label, "GPT-5.6-Terra")
    }

    func testCodexModelRowsShowResolvedModelOnDefaultRow() {
        let rows = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: nil, resolvedModel: "gpt-5.6-terra")
        XCTAssertEqual(rows[0].label, "Codex default (GPT-5.6-Terra)")
        // Resolved slug not in the catalog → raw slug in the label (honest fallback).
        let raw = AssistantModelOptions.codexModelRows(models: [], pinned: nil, resolvedModel: "gpt-7")
        XCTAssertEqual(raw[0].label, "Codex default (gpt-7)")
        // A PIN suppresses the resolved suffix (the default row isn't selected).
        let pinnedRows = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: "gpt-5.6-terra", resolvedModel: "gpt-5.6-terra")
        XCTAssertEqual(pinnedRows[0].label, "Codex default")
    }

    /// A pinned slug stays visible/selectable even when absent from the catalog
    /// (spec finding #6: never strand or silently rewrite a pin).
    func testCodexModelRowsKeepUnknownPinVisible() {
        let loaded = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: "gpt-5.5-pro", resolvedModel: nil)
        XCTAssertEqual(loaded.last?.value, "gpt-5.5-pro")
        XCTAssertEqual(loaded.last?.label, "gpt-5.5-pro — not offered by this codex")
        // Catalog not loaded yet (empty): keep the pin WITHOUT the warning suffix.
        let pending = AssistantModelOptions.codexModelRows(
            models: [], pinned: "gpt-5.5-pro", resolvedModel: nil)
        XCTAssertEqual(pending.map(\.value), [nil, "gpt-5.5-pro"])
        XCTAssertEqual(pending.last?.label, "gpt-5.5-pro")
        // A pinned slug IN the catalog is not duplicated.
        let known = AssistantModelOptions.codexModelRows(
            models: [terra], pinned: "gpt-5.6-terra", resolvedModel: nil)
        XCTAssertEqual(known.map(\.value), [nil, "gpt-5.6-terra"])
    }

    func testCodexEffortRowsFollowGoverningModelElseUniversal() {
        XCTAssertEqual(AssistantModelOptions.codexEffortRows(governing: terra).map(\.value),
                       ["low", "ultra"])
        // No governing model, or one with no effort data → the universal four.
        XCTAssertEqual(AssistantModelOptions.codexEffortRows(governing: nil).map(\.value),
                       ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(AssistantModelOptions.codexEffortRows(governing: sol).map(\.value),
                       ["low", "medium", "high", "xhigh"])
    }

    /// The picker never renders a blank selection: an out-of-list current effort is
    /// appended as a labeled trailing row; a listed one is not duplicated; nil is a
    /// no-op (the default-arg parity every existing call site relies on).
    func testCodexEffortRowsIncludeCurrentWhenUnlisted() {
        // `terra` offers [low, ultra]; a stored `max` (governing model lacks it) is
        // appended last with its display label.
        let withMax = AssistantModelOptions.codexEffortRows(governing: terra, includingCurrent: "max")
        XCTAssertEqual(withMax.map(\.value), ["low", "ultra", "max"])
        XCTAssertEqual(withMax.last?.label, "Max")
        // A current effort already in the list is NOT duplicated.
        XCTAssertEqual(
            AssistantModelOptions.codexEffortRows(governing: terra, includingCurrent: "low").map(\.value),
            ["low", "ultra"])
        // nil (and empty) current leaves the rows unchanged.
        XCTAssertEqual(
            AssistantModelOptions.codexEffortRows(governing: terra, includingCurrent: nil).map(\.value),
            ["low", "ultra"])
    }
}
#endif
