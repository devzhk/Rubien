#if os(macOS)
import XCTest
@testable import Rubien
import RubienCore

final class ScheduledJobEditorOptionsTests: XCTestCase {
    func testExistingAbsentOverridesStayUnpinnedWhileNewJobsUseDefaults() {
        XCTAssertEqual(ScheduledJobEditorOptions.initialOverride(
            savedValue: nil,
            defaultValue: "opus",
            isEditing: true
        ), "")
        XCTAssertEqual(ScheduledJobEditorOptions.initialOverride(
            savedValue: nil,
            defaultValue: "opus",
            isEditing: false
        ), "opus")
        XCTAssertEqual(ScheduledJobEditorOptions.initialOverride(
            savedValue: "saved-model",
            defaultValue: "opus",
            isEditing: true
        ), "saved-model")
    }

    func testNewJobDefaultsPreserveWebPreferenceAndEnableNotifications() {
        XCTAssertFalse(ScheduledJobEditorOptions.initialWebSearch(
            savedValue: nil,
            preference: false
        ))
        XCTAssertTrue(ScheduledJobEditorOptions.initialWebSearch(
            savedValue: nil,
            preference: true
        ))
        XCTAssertTrue(ScheduledJobEditorOptions.initialNotifyOnCompletion(savedValue: nil))

        XCTAssertTrue(ScheduledJobEditorOptions.initialWebSearch(
            savedValue: true,
            preference: false
        ))
        XCTAssertFalse(ScheduledJobEditorOptions.initialNotifyOnCompletion(savedValue: false))
    }

    func testClaudeRowsUseCuratedChoicesAndRetainUnknownSavedValues() {
        let models = ScheduledJobEditorOptions.modelRows(
            provider: .claude,
            codexModels: [],
            current: "future-model",
            catalogLoaded: true
        )
        XCTAssertEqual(models.map { $0.value }, ["fable", "opus", "sonnet", "future-model"])
        XCTAssertTrue(models.last?.label.contains("not offered") == true)

        let efforts = ScheduledJobEditorOptions.effortRows(
            provider: .claude,
            codexModels: [],
            model: "future-model",
            current: "future-effort"
        )
        XCTAssertEqual(efforts.last?.value, "future-effort")
        XCTAssertTrue(efforts.last?.label.contains("not offered") == true)
    }

    func testCodexRowsUseDiscoveredModelsAndSelectedModelsEfforts() {
        let models = [
            CodexModelInfo(
                id: "gpt-a",
                displayName: "GPT A",
                description: nil,
                efforts: [
                    CodexEffortInfo(value: "medium", label: "Medium", description: nil),
                    CodexEffortInfo(value: "ultra", label: "Ultra", description: nil),
                ],
                defaultEffort: "medium",
                isDefault: true,
                hidden: false
            ),
            CodexModelInfo(
                id: "gpt-b",
                displayName: "GPT B",
                description: nil,
                efforts: [CodexEffortInfo(value: "high", label: "High", description: nil)],
                defaultEffort: "high",
                isDefault: false,
                hidden: false
            ),
        ]

        let modelRows = ScheduledJobEditorOptions.modelRows(
            provider: .codex,
            codexModels: models,
            current: "gpt-a",
            catalogLoaded: true
        )
        XCTAssertEqual(modelRows.map { $0.value }, ["gpt-a", "gpt-b"])

        let effortRows = ScheduledJobEditorOptions.effortRows(
            provider: .codex,
            codexModels: models,
            model: "gpt-a",
            current: "ultra"
        )
        XCTAssertEqual(effortRows.map { $0.value }, ["medium", "ultra"])
    }

    func testCodexRowsRetainUnavailablePinnedModelAndDegradeToDefault() {
        let pinnedRows = ScheduledJobEditorOptions.modelRows(
            provider: .codex,
            codexModels: [],
            current: "retired-model",
            catalogLoaded: true
        )
        XCTAssertEqual(pinnedRows.map { $0.value }, ["retired-model"])

        let unavailableRows = ScheduledJobEditorOptions.modelRows(
            provider: .codex,
            codexModels: [],
            current: "",
            catalogLoaded: true
        )
        XCTAssertEqual(unavailableRows.map { $0.value }, [""])
        XCTAssertEqual(unavailableRows.first?.label, "Codex default")
    }

    func testCodexRowsRetainProviderDefaultAlongsideDiscoveredModels() {
        let model = CodexModelInfo(
            id: "gpt-a",
            displayName: "GPT A",
            description: nil,
            efforts: [],
            defaultEffort: nil,
            isDefault: true,
            hidden: false
        )
        let rows = ScheduledJobEditorOptions.modelRows(
            provider: .codex,
            codexModels: [model],
            current: "",
            catalogLoaded: true
        )
        XCTAssertEqual(rows.map { $0.value }, ["", "gpt-a"])
        XCTAssertEqual(rows.first?.label, "Codex default")
    }

    func testAbsentEffortHasProviderDefaultRow() {
        let rows = ScheduledJobEditorOptions.effortRows(
            provider: .claude,
            codexModels: [],
            model: "",
            current: ""
        )
        XCTAssertEqual(rows.first?.value, "")
        XCTAssertEqual(rows.first?.label, "Claude default")
    }
}
#endif
