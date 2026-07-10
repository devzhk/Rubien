# Markdown Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import any `.md` file (Obsidian Web Clipper output or plain notes) as a reference — via a new "Import PDF/Markdown" app button and an extended `rubien-cli import` — with a new first-class `Markdown` reference type.

**Architecture:** A pure `MarkdownImporter` parser in RubienCore feeds the existing `batchImportReferences` dedup/merge machinery (with a new fill-only merge policy). `ReferenceType` gains a `markdown` case wired end-to-end (icon, exports, CSL, migration v6 option seed, sync reconciliation, tolerant decode). The web-reader gate becomes content-driven so URL-less notes open in the reader.

**Tech Stack:** Swift 6.x, GRDB 7.10, SwiftUI/AppKit (app tasks), swift-argument-parser (CLI), TypeScript + zod + vitest (mcp-server).

**Spec:** `Docs/superpowers/specs/2026-07-09-markdown-import-design.md` — read it first; it holds the rationale for every rule below.

## Global Constraints

- macOS deployment target 15.0; Swift 6 strict concurrency; GRDB 7.10.
- **RubienCore and RubienCLI compile on Linux.** `MarkdownImporter` and all CLI code must use only Foundation APIs (no AppKit/PDFKit; no `os.Logger` — use `RubienLogger` if logging is ever needed; no CoreFoundation symbols without the `#if canImport(CoreFoundation)` dance).
- **Migrations are immutable once shipped.** All schema/data work goes in NEW `registerMigration("v6", ...)`. Never edit v1–v5 blocks.
- **Zero new CKRecord fields / zero new synced columns.** `SyncSchemaInvariantTests` must stay green.
- **CLI JSON output is a contract.** Existing shapes unchanged; only add.
- `Docs/CLI-Reference.md` updates ride the same commit as CLI behavior changes.
- The CLI test class is `RubienCLITests` (in `SwiftLibCLITests.swift`) — filter with `--filter RubienCLITests`. **"0 tests executed" is a FAILURE**, not a pass; always confirm the run count.
- Every file in `Tests/RubienSyncTests` is wrapped in `#if os(macOS)` … `#endif`.
- Commit after every task. Phase boundaries (after Tasks 7, 10, 12, 13) additionally get the repo's codex-rescue + `/simplify` review cycle before the phase is declared done.
- The Markdown select-option color is exactly **`#5AC8FA`**.

---

## Phase 1 — RubienCore

### Task 1: `ReferenceType.markdown` + tolerant decoding + every consumer switch

**Files:**
- Modify: `Sources/RubienCore/Models/Reference.swift` (enum at lines ~9–27; row decode at ~794)
- Modify: `Sources/RubienCore/Models/Reference+CSLJSON.swift` (`cslType`, lines 5–14)
- Modify: `Sources/RubienCore/Citation/CSLEngine.swift` (`mapReferenceType`, ~line 179)
- Modify: `Sources/RubienCore/Services/MetadataResolution.swift` (`workKind(for:)`, lines 331–344)
- Modify: `Sources/RubienCore/Services/MetadataVerifier.swift` (switch at ~line 19)
- Modify: `Sources/RubienCLI/RubienCLI.swift` (BibTeX `entryType` switch ~line 1626; RIS `risType` switch ~lines 1653–1661)
- Test: `Tests/RubienCoreTests/ReferenceTests.swift` (allCases count at line 68)
- Test: `Tests/RubienCoreTests/ReferenceTypeDecodingTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ReferenceType.markdown` (rawValue `"Markdown"`), tolerant `ReferenceType.init(from:)` (JSON decode falls back to `.other`), tolerant GRDB row decode of `reference.referenceType`. Later tasks construct `Reference(referenceType: .markdown)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RubienCoreTests/ReferenceTypeDecodingTests.swift`:

```swift
import XCTest
import GRDB
@testable import RubienCore

final class ReferenceTypeDecodingTests: XCTestCase {

    func testMarkdownCaseExists() {
        XCTAssertEqual(ReferenceType.markdown.rawValue, "Markdown")
        XCTAssertEqual(ReferenceType.markdown.icon, "doc.plaintext")
    }

    /// A newer peer may persist a rawValue this binary doesn't know.
    /// JSON decoding must fall back to .other, never throw — Reference is
    /// embedded in persisted metadata-intake JSON.
    func testUnknownRawValueJSONDecodesToOther() throws {
        let json = Data(#""Hologram""#.utf8)
        let decoded = try JSONDecoder().decode(ReferenceType.self, from: json)
        XCTAssertEqual(decoded, .other)
    }

    func testKnownRawValueJSONDecodesExactly() throws {
        let json = Data(#""Markdown""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ReferenceType.self, from: json), .markdown)
    }

    /// GRDB row decode of an unknown stored rawValue must not trap
    /// (downgrade / app-CLI skew on a shared library).
    func testUnknownRawValueRowDecodesToOther() throws {
        let db = try AppDatabase(DatabaseQueue())
        var ref = Reference(title: "Future type row")
        _ = try db.saveReference(&ref)
        try db.dbWriter.write { d in
            try d.execute(
                sql: "UPDATE reference SET referenceType = 'Hologram' WHERE id = ?",
                arguments: [ref.id]
            )
        }
        let fetched = try db.fetchReferences(ids: [ref.id!]).first
        XCTAssertEqual(fetched?.referenceType, .other)
    }

    func testCSLExportMapping() {
        XCTAssertEqual(ReferenceType.markdown.cslType, "document")
    }
}
```

In `Tests/RubienCoreTests/ReferenceTests.swift` line 68, change:

```swift
XCTAssertEqual(ReferenceType.allCases.count, 7)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ReferenceTypeDecodingTests 2>&1 | tail -20`
Expected: FAIL — `type 'ReferenceType' has no member 'markdown'` (compile error counts as the failing state).

- [ ] **Step 3: Implement**

In `Sources/RubienCore/Models/Reference.swift`, extend the enum (and update the stale header comment at lines 4–8, which still says webpage alone gates the reader — Task 4 changes that gate):

```swift
/// Pruned 2026-05 (v3) from 21 cases to 6; `markdown` added 2026-07 for
/// imported markdown notes. Type maps 1:1 to BibTeX entry types;
/// categorization beyond that goes to Tags or custom singleSelect
/// properties. The web reader opens for ANY type with stored `webContent`
/// (`Reference.canOpenWebReader`); `webpage` additionally gets URL-only
/// live mode.
public enum ReferenceType: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case journalArticle  = "Journal Article"
    case conferencePaper = "Conference Paper"
    case book            = "Book"
    case thesis          = "Thesis"
    case webpage         = "Web Page"
    case markdown        = "Markdown"
    case other           = "Other"

    public var icon: String {
        switch self {
        case .journalArticle:  return "doc.text"
        case .conferencePaper: return "person.3"
        case .book:            return "book.closed"
        case .thesis:          return "graduationcap"
        case .webpage:         return "globe"
        case .markdown:        return "doc.plaintext"
        case .other:           return "doc"
        }
    }

    /// Tolerant decode: a newer peer may write rawValues this binary doesn't
    /// know. Fall back to `.other` instead of throwing — Reference is embedded
    /// in persisted JSON (pending metadata-intake queue) and synced records.
    /// Encoding stays the synthesized rawValue encode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReferenceType(rawValue: raw) ?? .other
    }
}
```

In `Reference.init(row:)` (~line 794), replace:

```swift
referenceType = row["referenceType"]
```

with:

```swift
// Tolerant decode: unknown rawValue (newer binary wrote this library) → .other,
// mirroring ReferenceRecord's CKRecord fallback. The plain subscript would trap.
let referenceTypeRaw: String? = row["referenceType"]
referenceType = referenceTypeRaw.flatMap(ReferenceType.init(rawValue:)) ?? .other
```

Compiler-forced switch updates (fold into existing lines where shown):

- `Reference+CSLJSON.swift` `cslType`: add `case .markdown: return "document"`.
- `CSLEngine.swift` `mapReferenceType`: add `case .markdown: return "document"`.
- `MetadataResolution.swift` `workKind(for:)`: change `case .webpage, .other:` to `case .webpage, .other, .markdown:`.
- `MetadataVerifier.swift` ~line 19: change `case .journalArticle, .conferencePaper, .webpage, .other:` to `case .journalArticle, .conferencePaper, .webpage, .other, .markdown:`.
- `RubienCLI.swift` BibTeX export (~1626): fold `.markdown` into the misc line so it reads `case .webpage, .other, .markdown: entryType = "misc"`.
- `RubienCLI.swift` RIS export (~1655): change `case .other: risType = "GEN"` to `case .other, .markdown: risType = "GEN"`.

Build once to let the compiler list any switch this plan missed, then fix those the same way (`.markdown` behaves like `.other` unless the spec says otherwise):

Run: `swift build 2>&1 | grep -E 'error' | head -20`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ReferenceTypeDecodingTests 2>&1 | tail -5` → PASS
Run: `swift test --filter ReferenceTests 2>&1 | tail -5` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore Sources/RubienCLI Tests/RubienCoreTests
git commit -m "feat(core): add ReferenceType.markdown with tolerant decoding"
```

---

### Task 2: Option-append helper + migration v6

**Files:**
- Modify: `Sources/RubienCore/Database/AppDatabase.swift` (migrator: add `registerMigration("v6")` after the `"v5"` block at ~line 553; new `applyV6Body` + `runV6MigrationForTesting` next to `runV2MigrationForTesting` at ~line 649)
- Create: `Sources/RubienCore/Database/TypeOptionsReconciler.swift`
- Test: `Tests/RubienCoreTests/MigrationV6Tests.swift` (create)

**Interfaces:**
- Consumes: `ReferenceType.allCases` (Task 1), `SelectOption(value:color:)`.
- Produces: `TypeOptionsReconciler.appendingMissingTypeOptions(toOptionsJSON:) -> String?` (nil = leave untouched) and `AppDatabase.runV6MigrationForTesting(on:)`. Task 3 reuses the reconciler.

**Note (spec alignment):** the spec words v6 as "append Markdown"; this task appends *every missing enum-backed option* via the shared reconciler. The two are equivalent in every reachable state — migration v3 rewrote the options to exactly the six enum-backed values and Type options are not user-editable — and one shared code path beats two. Task 10 records this equivalence in the spec.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RubienCoreTests/MigrationV6Tests.swift`:

```swift
import XCTest
import GRDB
@testable import RubienCore

final class MigrationV6Tests: XCTestCase {

    /// The realistic v5-era six-option state (v3 prune output), plus one
    /// forward-compat unknown field that must survive structurally.
    private let sixOptionsJSON = #"[{"value":"Journal Article","color":"#007AFF"},{"value":"Conference Paper","color":"#AF52DE"},{"value":"Book","color":"#34C759"},{"value":"Thesis","color":"#FF9500"},{"value":"Web Page","color":"#30B0C7"},{"value":"Other","color":"#8E8E93","futureField":"keep-me"}]"#

    private func typeOptionsJSON(_ db: AppDatabase) throws -> String {
        try db.dbWriter.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey = 'referenceType'"
            ) ?? ""
        }
    }

    private func markdownCount(in json: String) -> Int {
        json.components(separatedBy: "\"Markdown\"").count - 1
    }

    /// Sets the Type options fixture WITHOUT leaving dirty syncState behind:
    /// the fixture write itself trips the dirty trigger, so clear syncState
    /// afterwards — the assertions must observe only the subject under test.
    private func setTypeOptionsFixture(_ db: AppDatabase, json: String) throws {
        try db.dbWriter.write { d in
            try d.execute(
                sql: "UPDATE propertyDefinition SET optionsJSON = ? WHERE defaultFieldKey = 'referenceType'",
                arguments: [json]
            )
            try d.execute(sql: "DELETE FROM syncState", arguments: [])
        }
    }

    private func typeDefinitionId(_ db: AppDatabase) throws -> Int64 {
        try db.dbWriter.read { d in
            try Int64.fetchOne(
                d,
                sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey = 'referenceType'"
            ) ?? -1
        }
    }

    func testFreshDatabaseHasMarkdownOptionOnce() throws {
        let db = try AppDatabase(DatabaseQueue())
        XCTAssertEqual(markdownCount(in: try typeOptionsJSON(db)), 1)
    }

    func testAppendIsIdempotentAndPreservesExistingOptions() throws {
        let db = try AppDatabase(DatabaseQueue())
        try setTypeOptionsFixture(db, json: sixOptionsJSON)
        guard let queue = db.dbWriter as? DatabaseQueue else { return XCTFail("expected queue") }

        try AppDatabase.runV6MigrationForTesting(on: queue)
        var json = try typeOptionsJSON(db)
        XCTAssertEqual(markdownCount(in: json), 1)
        XCTAssertTrue(json.contains("Journal Article"), "existing options preserved")
        XCTAssertTrue(json.contains("#30B0C7"), "existing colors preserved")
        XCTAssertTrue(json.contains("futureField"), "unknown JSON fields preserved")

        try AppDatabase.runV6MigrationForTesting(on: queue)   // idempotence
        json = try typeOptionsJSON(db)
        XCTAssertEqual(markdownCount(in: json), 1)
    }

    func testMalformedOptionsJSONLeftUntouched() throws {
        let db = try AppDatabase(DatabaseQueue())
        try setTypeOptionsFixture(db, json: "not json")
        guard let queue = db.dbWriter as? DatabaseQueue else { return XCTFail("expected queue") }
        try AppDatabase.runV6MigrationForTesting(on: queue)
        XCTAssertEqual(try typeOptionsJSON(db), "not json", "fail-safe no-op on undecodable data")
    }

    /// The applyingRemote guard must suppress dirty-tracking for the Type row:
    /// migrations are local normalization, not user edits.
    func testMigrationEmitsNoDirtySyncStateForTypeRow() throws {
        let db = try AppDatabase(DatabaseQueue())
        try setTypeOptionsFixture(db, json: sixOptionsJSON)   // also clears syncState
        guard let queue = db.dbWriter as? DatabaseQueue else { return XCTFail("expected queue") }
        try AppDatabase.runV6MigrationForTesting(on: queue)

        let typeId = try typeDefinitionId(db)
        let dirty = try db.dbWriter.read { d in
            try Int.fetchOne(
                d,
                sql: """
                    SELECT COUNT(*) FROM syncState
                    WHERE entityType = 'propertyDefinition' AND entityId = ? AND isDirty = 1
                    """,
                arguments: [String(typeId)]
            ) ?? 0
        }
        XCTAssertEqual(dirty, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MigrationV6Tests 2>&1 | tail -10`
Expected: FAIL — `runV6MigrationForTesting` undefined / fresh DB lacks the option.

- [ ] **Step 3: Implement**

Create `Sources/RubienCore/Database/TypeOptionsReconciler.swift`:

```swift
import Foundation

/// Shared by migration v6 and the sync remote-apply reconciliation: append
/// any enum-backed Type option missing from an `optionsJSON` array.
/// Structural JSON edit — existing objects (order, colors, unknown fields)
/// are preserved; only missing options are appended. In practice only
/// "Markdown" can be missing (v3 guaranteed the other six), but healing all
/// enum cases keeps one code path for both callers.
public enum TypeOptionsReconciler {

    /// Default chip colors per enum-backed option, mirroring the v1 seed /
    /// v3 prune palette. Used only when appending a missing option.
    static let defaultColors: [ReferenceType: String] = [
        .journalArticle:  "#007AFF",
        .conferencePaper: "#AF52DE",
        .book:            "#34C759",
        .thesis:          "#FF9500",
        .webpage:         "#30B0C7",
        .markdown:        "#5AC8FA",
        .other:           "#8E8E93",
    ]

    /// Returns the amended JSON, the input string itself when nothing is
    /// missing, or nil when the input is not a JSON array of objects
    /// (caller must leave the stored value untouched — fail-safe).
    public static func appendingMissingTypeOptions(toOptionsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var array = parsed as? [[String: Any]] else {
            return nil
        }
        let present = Set(array.compactMap { $0["value"] as? String })
        var appended = false
        for type in ReferenceType.allCases where !present.contains(type.rawValue) {
            array.append([
                "value": type.rawValue,
                "color": defaultColors[type] ?? "#8E8E93",
            ])
            appended = true
        }
        guard appended else { return json }
        guard let out = try? JSONSerialization.data(withJSONObject: array),
              let str = String(data: out, encoding: .utf8) else {
            return nil
        }
        return str
    }
}
```

In `AppDatabase.swift`, directly after the `registerMigration("v5")` block (~line 553):

```swift
migrator.registerMigration("v6") { db in
    try Self.applyV6Body(db)
}
```

Next to `runV2MigrationForTesting` (~line 649), add:

```swift
/// v6 migration body: ensure the Type PropertyDefinition advertises every
/// enum-backed option (adds "Markdown"). Runs under the applyingRemote
/// guard for the same reason v3 did: local normalization, not a user edit,
/// so it must not queue a CloudKit push. Convergence across devices comes
/// from every device running this locally plus the remote-apply
/// reconciliation in RubienSync.
fileprivate static func applyV6Body(_ db: Database) throws {
    try db.execute(sql: """
        INSERT INTO syncSession(key, value) VALUES('applyingRemote','1')
            ON CONFLICT(key) DO UPDATE SET value='1'
    """)
    defer {
        try? db.execute(sql: "DELETE FROM syncSession WHERE key='applyingRemote'")
    }
    guard let current = try String.fetchOne(
        db,
        sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey = 'referenceType' LIMIT 1"
    ) else { return }
    guard let amended = TypeOptionsReconciler.appendingMissingTypeOptions(toOptionsJSON: current),
          amended != current else {
        return  // malformed (nil) → leave untouched; unchanged → nothing to do
    }
    try db.execute(
        sql: "UPDATE propertyDefinition SET optionsJSON = ? WHERE defaultFieldKey = 'referenceType'",
        arguments: [amended]
    )
}

/// Test-only: applies the v6 body to an already-migrated queue so tests can
/// simulate the v5-shaped / peer-overwritten state and verify idempotence.
public static func runV6MigrationForTesting(on queue: DatabaseQueue) throws {
    try queue.write { db in
        try applyV6Body(db)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MigrationV6Tests 2>&1 | tail -5` → PASS
Run: `swift test --filter SyncSchemaInvariantTests 2>&1 | tail -5` → PASS (no synced-column drift)

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore Tests/RubienCoreTests
git commit -m "feat(core): migration v6 seeds the Markdown type option (fail-safe JSON append)"
```

---

### Task 3: Sync reconciliation for the Type built-in

**Files:**
- Modify: `Sources/RubienSync/SyncEntityDispatch.swift` (`.propertyDefinition` branch, built-in path at ~lines 466–482)
- Test: `Tests/RubienSyncTests/TypeOptionsReconciliationTests.swift` (create)

**Interfaces:**
- Consumes: `TypeOptionsReconciler.appendingMissingTypeOptions(toOptionsJSON:)` (Task 2); `PropertyDefinition.optionsJSON` (stored `String` property); `PropertyDefinition.makeRecord(recordName:definition:)`; `SyncEntityType.propertyDefinition.qualifiedRecordName(entityId:)` and `.applyRemoteRecord(_:entityId:db:)`; `SyncStateStore().setApplyingRemote(_:)` / `.clearApplyingRemote(_:)` (all demonstrated in `Tests/RubienSyncTests/PropertyDefinitionReconcileTests.swift` — read it first).
- Produces: remote-apply healing — applying a remote Type definition can never drop enum-backed options.

- [ ] **Step 1: Write the failing test**

Create `Tests/RubienSyncTests/TypeOptionsReconciliationTests.swift` (mirrors `PropertyDefinitionReconcileTests` — same imports, same `#if os(macOS)` wrapper):

```swift
#if os(macOS)
import XCTest
import GRDB
import CloudKit
@testable import RubienCore
@testable import RubienSync

/// Spec §2 (markdown-import design): `optionsJSON` syncs verbatim, so an
/// old peer pushing the six-option Type definition would silently remove
/// the "Markdown" option and the v6 migration never reruns. The apply path
/// must heal enum-backed options — without dirtying the record.
final class TypeOptionsReconciliationTests: XCTestCase {
    private var db: AppDatabase!
    private let store = SyncStateStore()

    override func setUpWithError() throws {
        try super.setUpWithError()
        db = try AppDatabase(DatabaseQueue())
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    private let sixOptions: [SelectOption] = [
        .init(value: "Journal Article",  color: "#007AFF"),
        .init(value: "Conference Paper", color: "#AF52DE"),
        .init(value: "Book",             color: "#34C759"),
        .init(value: "Thesis",           color: "#FF9500"),
        .init(value: "Web Page",         color: "#30B0C7"),
        .init(value: "Other",            color: "#8E8E93"),
    ]

    func testRemoteSixOptionTypeDefinitionIsHealed() throws {
        let localId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='referenceType'")
        })

        let def = PropertyDefinition(
            id: localId, name: "Type", type: .singleSelect, options: sixOptions,
            sortOrder: 0, isDefault: true, defaultFieldKey: "referenceType", isVisible: true
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(localId)),
            definition: def
        )

        try db.dbWriter.write { d in
            // Start from a clean slate so the dirty assertion below observes
            // only the apply path, not earlier migration/seed writes.
            try d.execute(sql: "DELETE FROM syncState", arguments: [])
            try self.store.setApplyingRemote(d)
            _ = try SyncEntityType.propertyDefinition.applyRemoteRecord(
                record, entityId: String(localId), db: d
            )
            try self.store.clearApplyingRemote(d)
        }

        let stored = try db.dbWriter.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey='referenceType'"
            ) ?? ""
        }
        XCTAssertTrue(stored.contains(#""Markdown""#), "reconciliation re-appends the enum-backed option")
        XCTAssertTrue(stored.contains("Journal Article"), "incoming options preserved")

        let dirty = try db.dbWriter.read { d in
            try Int.fetchOne(
                d,
                sql: """
                    SELECT COUNT(*) FROM syncState
                    WHERE entityType = 'propertyDefinition' AND entityId = ? AND isDirty = 1
                    """,
                arguments: [String(localId)]
            ) ?? 0
        }
        XCTAssertEqual(dirty, 0, "healing must not push back")
    }

    /// Non-Type built-ins must pass through untouched (no accidental healing).
    func testNonTypeBuiltinIsNotTouched() throws {
        let localId = try XCTUnwrap(try db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'")
        })
        let def = PropertyDefinition(
            id: localId, name: "Last Read", type: .date, options: [],
            sortOrder: 9, isDefault: true, defaultFieldKey: "lastReadAt", isVisible: false
        )
        let record = PropertyDefinition.makeRecord(
            recordName: SyncEntityType.propertyDefinition.qualifiedRecordName(entityId: String(localId)),
            definition: def
        )
        try db.dbWriter.write { d in
            try self.store.setApplyingRemote(d)
            _ = try SyncEntityType.propertyDefinition.applyRemoteRecord(
                record, entityId: String(localId), db: d
            )
            try self.store.clearApplyingRemote(d)
        }
        let stored = try db.dbWriter.read { d in
            try String.fetchOne(
                d,
                sql: "SELECT optionsJSON FROM propertyDefinition WHERE defaultFieldKey='lastReadAt'"
            ) ?? ""
        }
        XCTAssertFalse(stored.contains("Markdown"))
    }
}
#endif
```

Also extend the existing `Tests/RubienSyncTests/` reference round-trip suite (the file whose tests build a reference record via `Reference.makeRecord`-style helpers and decode with `Reference(record:)` — locate it with `grep -rln "Reference(record:" Tests/RubienSyncTests/`) with one case, following that file's existing helper style exactly:

```swift
func testMarkdownReferenceTypeRoundTrips() throws {
    // Build/encode/decode exactly like the sibling tests in this file,
    // with referenceType: .markdown — assert it survives the round trip.
}
```

(The body is three lines in that file's idiom; copy a sibling test and change the type. The assertion that matters: decoded `referenceType == .markdown`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TypeOptionsReconciliationTests 2>&1 | tail -10`
Expected: FAIL — stored JSON lacks `"Markdown"` after apply. Confirm the run count is ≥ 2 tests.

- [ ] **Step 3: Implement**

In `SyncEntityDispatch.swift`, `.propertyDefinition` case, inside the
built-in branch (`if let fieldKey = row.defaultFieldKey, let localId = ...`),
immediately after `row.isDefault = true` and before `try row.update(db)`:

```swift
// Type built-in: never let a peer's options list drop enum-backed
// options (an old peer pushes six options → "Markdown" would vanish
// and the v6 migration never reruns). Heal structurally (unknown JSON
// fields preserved); the applyingRemote guard already active during
// pulls keeps this from dirtying the record — every device heals
// itself, no push-back churn.
if fieldKey == "referenceType",
   let healed = TypeOptionsReconciler.appendingMissingTypeOptions(toOptionsJSON: row.optionsJSON) {
    row.optionsJSON = healed
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RubienSyncTests 2>&1 | tail -5` → PASS (whole target — round-trip and reconcile suites must stay green)

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienSync Tests/RubienSyncTests
git commit -m "fix(sync): heal enum-backed Type options on remote PropertyDefinition apply"
```

---

### Task 4: Content-driven `canOpenWebReader`

**Files:**
- Modify: `Sources/RubienCore/Models/Reference.swift` (`canOpenWebReader`, lines ~739–746)
- Test: `Tests/RubienCoreTests/ReferenceTests.swift` (append tests)

**Interfaces:**
- Produces: `canOpenWebReader == true` for ANY reference with non-empty `webContent`. App task 12 mirrors this in `ReferenceDetailView`.

- [ ] **Step 1: Write the failing tests** (append to `ReferenceTests.swift`)

```swift
func testCanOpenWebReaderIsContentDriven() {
    var note = Reference(title: "note", referenceType: .markdown)
    XCTAssertFalse(note.canOpenWebReader, "no content, no URL → closed")

    note.webContent = Reference.encodeWebContent("# hello", format: .markdown)
    XCTAssertTrue(note.canOpenWebReader, "any type with content opens")

    var article = Reference(title: "a", referenceType: .journalArticle)
    article.webContent = Reference.encodeWebContent("body", format: .markdown)
    XCTAssertTrue(article.canOpenWebReader, "clip survives a type change")

    let urlOnly = Reference(title: "w", url: "https://example.com", referenceType: .webpage)
    XCTAssertTrue(urlOnly.canOpenWebReader, "webpage URL-only live mode unchanged")

    let otherWithURL = Reference(title: "o", url: "https://example.com", referenceType: .other)
    XCTAssertFalse(otherWithURL.canOpenWebReader, "URL-only live mode stays webpage-gated")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ReferenceTests 2>&1 | tail -10`
Expected: FAIL on the `.markdown`/`journalArticle` content cases.

- [ ] **Step 3: Implement** — replace the body of `canOpenWebReader` (keep a Chinese doc comment in the file's style, updated to: 有剪藏正文即可打开（任意类型）；仅 `webpage` 类型才有仅凭链接的在线阅读):

```swift
public var canOpenWebReader: Bool {
    let clip = webContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !clip.isEmpty { return true }
    guard referenceType == .webpage else { return false }
    let urlStr = resolvedWebReaderURLString()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !urlStr.isEmpty && URL(string: urlStr) != nil
}
```

- [ ] **Step 4: Run tests** — `swift test --filter ReferenceTests 2>&1 | tail -5` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore Tests/RubienCoreTests
git commit -m "feat(core): web reader gate is content-driven, live mode stays webpage-only"
```

---

### Task 5: `MarkdownImporter` — detection, plausibility, title chain, body

**Files:**
- Create: `Sources/RubienCore/Services/MarkdownImporter.swift`
- Test: `Tests/RubienCoreTests/MarkdownImporterTests.swift` (create)

**Interfaces:**
- Produces: `MarkdownImporter.parse(_ content: String, filename: String?) -> Reference` — never throws, never returns nil. Task 6 extends the same file with field mapping; Tasks 7–9, 12 call `parse`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RubienCoreTests/MarkdownImporterTests.swift`:

```swift
import XCTest
@testable import RubienCore

final class MarkdownImporterTests: XCTestCase {

    // MARK: Title chain & body

    func testH1FirstLineBecomesTitleAndIsRemovedFromBody() {
        let ref = MarkdownImporter.parse("# My Note\n\nBody text.", filename: "file")
        XCTAssertEqual(ref.title, "My Note")
        let body = ref.decodedWebContent
        XCTAssertEqual(body?.format, .markdown)
        XCTAssertEqual(body?.body, "Body text.")
        XCTAssertEqual(ref.referenceType, .markdown)
    }

    func testFilenameFallbackWhenNoH1() {
        let ref = MarkdownImporter.parse("Just some text.", filename: "Meeting Notes")
        XCTAssertEqual(ref.title, "Meeting Notes")
        XCTAssertEqual(ref.decodedWebContent?.body, "Just some text.")
    }

    func testUntitledFallbackForStdin() {
        let ref = MarkdownImporter.parse("text", filename: nil)
        XCTAssertEqual(ref.title, "Untitled")
    }

    func testEmptyH1DoesNotBecomeTitle() {
        let ref = MarkdownImporter.parse("# \nBody", filename: "fallback")
        XCTAssertEqual(ref.title, "fallback")
        XCTAssertEqual(ref.decodedWebContent?.body, "# \nBody")
    }

    func testH2IsNotATitle() {
        let ref = MarkdownImporter.parse("## Section\nBody", filename: "f")
        XCTAssertEqual(ref.title, "f")
    }

    func testEmptyFileImportsMetadataOnly() {
        let ref = MarkdownImporter.parse("", filename: "empty")
        XCTAssertEqual(ref.title, "empty")
        XCTAssertNil(ref.webContent)
    }

    // MARK: Frontmatter detection / plausibility

    func testPlausibleFrontmatterIsStrippedEvenIfUnrecognized() {
        let md = "---\naliases:\n  - alt-name\n---\nBody here."
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, "Body here.")
        XCTAssertEqual(ref.title, "f", "unrecognized keys contribute no metadata")
    }

    func testThematicBreakDocumentIsNotFrontmatter() {
        let md = "---\nThis is prose between thematic breaks.\n---\nMore prose."
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, md, "nothing stripped")
    }

    /// Spec §1: list items must be indented under their key. An unindented
    /// `- item` is a markdown bullet list, not YAML — the candidate block is
    /// implausible and the document must be preserved verbatim.
    func testUnindentedDashLinesAreNotFrontmatter() {
        let md = "---\ntitle: looks-like-yaml\n- but this is a bullet\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, md, "implausible block preserved verbatim")
        XCTAssertEqual(ref.title, "f")
    }

    func testUnclosedFrontmatterTreatsWholeFileAsBody() {
        let md = "---\ntitle: Oops no closer\nBody."
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, md)
        XCTAssertEqual(ref.title, "f")
    }

    func testBOMAndCRLFTolerated() {
        let md = "\u{FEFF}---\r\ntitle: CRLF Note\r\n---\r\nBody\r\n"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.title, "CRLF Note")
        XCTAssertEqual(ref.decodedWebContent?.body, "Body")
    }

    func testFrontmatterOnlyFileHasNilContent() {
        let ref = MarkdownImporter.parse("---\ntitle: Only Meta\n---\n", filename: "f")
        XCTAssertEqual(ref.title, "Only Meta")
        XCTAssertNil(ref.webContent)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter MarkdownImporterTests 2>&1 | tail -10`
Expected: FAIL — `MarkdownImporter` undefined.

- [ ] **Step 3: Implement**

Create `Sources/RubienCore/Services/MarkdownImporter.swift`. This step
delivers the skeleton: line classification, plausibility, title chain,
body assembly, and a `fields` dictionary that Task 6 maps to Reference
fields (only `title` is consumed here).

```swift
import Foundation

/// Parses a markdown file (Obsidian Web Clipper output or any plain note)
/// into a `Reference`. Pure — no I/O, no database, Linux-safe.
///
/// Frontmatter is optional enrichment. A leading `---` block is stripped
/// only when it is *plausible YAML mapping* (spec §1): every non-blank line
/// classifies as top-level key / indented list item / indented continuation
/// / comment, and at least one top-level key exists. Anything else — e.g.
/// thematic breaks, bullet lists — is body and preserved verbatim.
public enum MarkdownImporter {

    /// A parsed frontmatter value: scalar or list of scalars.
    enum FrontmatterValue {
        case scalar(String)
        case list([String])
    }

    public static func parse(_ content: String, filename: String?) -> Reference {
        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }

        let block = frontmatterBlock(in: lines)
        var bodyLines = block.map { Array(lines[($0.closingIndex + 1)...]) } ?? lines
        let fields = block?.fields ?? [:]

        // Title chain: frontmatter → first-line H1 (removed) → filename → "Untitled".
        var title = scalar(fields["title"])
        if title == nil,
           let idx = bodyLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           bodyLines[idx].hasPrefix("# ") {
            let heading = String(bodyLines[idx].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty {
                title = heading
                bodyLines.remove(at: idx)
            }
        }
        let resolvedTitle = title ?? filename ?? "Untitled"

        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return makeReference(title: resolvedTitle, fields: fields, body: body)
    }

    // MARK: - Frontmatter block

    private struct Block {
        var fields: [String: FrontmatterValue]
        var closingIndex: Int
    }

    /// `key:` / `key: value` at indentation 0. Key charset per spec §1.
    private static let keyPattern = /^([A-Za-z0-9_-]+):(.*)$/

    /// Valid block-scalar headers: `|`, `>`, with optional indentation
    /// indicator and/or chomping modifier (`|-`, `>+`, `|2`, `>2-`, …).
    private static let blockScalarPattern = /^[|>][0-9]*[+-]?$/

    private static func frontmatterBlock(in lines: [String]) -> Block? {
        guard lines.first == "---" else { return nil }
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return nil }

        var fields: [String: FrontmatterValue] = [:]
        var openListKey: String?                 // key awaiting indented `- item` lines
        var inBlockScalar = false                // consuming `|`/`>` continuations
        var sawKey = false

        for raw in lines[1..<close] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }                       // comment

            let indented = raw.first == " " || raw.first == "\t"

            if indented {
                if inBlockScalar { continue }                            // scalar continuation
                if let key = openListKey, trimmed.hasPrefix("- ") || trimmed == "-" {
                    appendListItem(String(trimmed.dropFirst(1)), to: key, in: &fields)
                    continue
                }
                if openListKey != nil || sawKey { continue }             // nested map / continuation: opaque
                return nil                                               // indented line with no owner
            }

            // Unindented, non-key, non-comment content (including `- item`
            // bullets — spec requires list items to be indented) makes the
            // candidate implausible: preserve the whole document as body.
            inBlockScalar = false
            guard let match = raw.wholeMatch(of: keyPattern) else { return nil }
            sawKey = true
            openListKey = nil
            let key = String(match.1)
            let rawValue = String(match.2).trimmingCharacters(in: .whitespaces)

            if rawValue.isEmpty {
                openListKey = key                                        // may open a block list
                continue
            }
            if rawValue.wholeMatch(of: blockScalarPattern) != nil {
                inBlockScalar = true                                     // unsupported: consume, no metadata
                continue
            }
            if fields[key] == nil {
                fields[key] = .scalar(rawValue)
            }
        }

        guard sawKey else { return nil }
        return Block(fields: fields, closingIndex: close)
    }

    private static func appendListItem(
        _ raw: String, to key: String, in fields: inout [String: FrontmatterValue]
    ) {
        let item = raw.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return }
        switch fields[key] {
        case .list(var items):
            items.append(item)
            fields[key] = .list(items)
        case .scalar, nil:
            fields[key] = .list([item])
        }
    }

    // MARK: - Scalar helpers

    static func scalar(_ value: FrontmatterValue?) -> String? {
        guard case .scalar(let raw)? = value else { return nil }
        let unquoted = unquote(raw)
        return unquoted.isEmpty ? nil : unquoted
    }

    /// Strip one layer of matching quotes. Double quotes unescape `\"` and
    /// `\\`; single quotes unescape `''`. Unknown escapes stay literal.
    static func unquote(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    /// Task 6 replaces this stub with full field mapping.
    private static func makeReference(
        title: String, fields: [String: FrontmatterValue], body: String
    ) -> Reference {
        Reference(
            title: title,
            webContent: Reference.encodeWebContent(body, format: .markdown),
            referenceType: .markdown
        )
    }
}
```

- [ ] **Step 4: Run tests** — `swift test --filter MarkdownImporterTests 2>&1 | tail -5` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Services/MarkdownImporter.swift Tests/RubienCoreTests/MarkdownImporterTests.swift
git commit -m "feat(core): MarkdownImporter skeleton — frontmatter plausibility, title chain, body"
```

---

### Task 6: `MarkdownImporter` — field mapping (authors, dates, source, flow lists)

**Files:**
- Modify: `Sources/RubienCore/Services/MarkdownImporter.swift`
- Modify: `Tests/RubienCoreTests/MarkdownImporterTests.swift`

**Interfaces:**
- Consumes: `AuthorName.parse(_:)`, `Reference` init (Task 5's construction extended).
- Produces: complete clipper-field mapping per spec §1 table.

- [ ] **Step 1: Write the failing tests** (append to `MarkdownImporterTests.swift`)

```swift
    // MARK: Full clipper fixture (mirrors a real Obsidian Web Clipper file)

    func testObsidianClipperFixtureMapsAllFields() {
        let md = """
        ---
        title: "Solving OPSD (basically)"
        source: "https://x.com/ar0cket1/article/2065772402622263701"
        author:
          - "[[ar0cket1 (@ar0cket1)]]"
        published: 2026-06-13
        created: 2026-07-09
        description: "self hinted teachers will likely be common practice."
        tags:
          - "clippings"
        ---
        ![Image](https://example.com/img.jpg)

        Body paragraph.
        """
        let ref = MarkdownImporter.parse(md, filename: "Solving OPSD (basically)")
        XCTAssertEqual(ref.title, "Solving OPSD (basically)")
        XCTAssertEqual(ref.url, "https://x.com/ar0cket1/article/2065772402622263701")
        XCTAssertEqual(ref.siteName, "x.com")
        XCTAssertEqual(ref.referenceType, .webpage)
        XCTAssertEqual(ref.year, 2026)
        XCTAssertEqual(ref.issuedMonth, 6)
        XCTAssertEqual(ref.issuedDay, 13)
        XCTAssertEqual(ref.accessedDate, "2026-07-09")
        XCTAssertEqual(ref.abstract, "self hinted teachers will likely be common practice.")
        XCTAssertEqual(ref.authors.count, 1)
        XCTAssertFalse(ref.authors[0].displayName.contains("[["), "wiki-link wrapper stripped")
        XCTAssertEqual(ref.decodedWebContent?.body, "![Image](https://example.com/img.jpg)\n\nBody paragraph.")
    }

    // MARK: Authors

    func testFlowListAuthorsRespectQuotedCommas() {
        let md = "---\nauthor: [\"Smith, John\", \"[[Jane Doe]]\"]\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.authors.count, 2)
        XCTAssertEqual(ref.authors[0].family, "Smith")
        XCTAssertEqual(ref.authors[0].given, "John")
        XCTAssertEqual(ref.authors[1].displayName, "Jane Doe")
    }

    func testFlowListNestedBracketsDoNotSplit() {
        let md = "---\nauthor: [\"Lab [Systems, Core]\", Solo Author]\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.authors.count, 2, "comma inside nested brackets must not split")
    }

    func testScalarAuthor() {
        let md = "---\nauthor: Jane Doe\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.authors.count, 1)
        XCTAssertEqual(ref.authors[0].displayName, "Jane Doe")
    }

    func testUnsupportedEscapesStayLiteral() {
        let md = "---\ndescription: \"line\\nbreak\"\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.abstract, "line\\nbreak", "\\n is not an unescape we support")
    }

    // MARK: Nested keys must not leak (spec §1 / codex finding 5)

    func testNestedTitleDoesNotLeak() {
        let md = "---\nmetadata:\n  title: Wrong\nsource: https://example.com/x\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "right")
        XCTAssertEqual(ref.title, "right")
        XCTAssertEqual(ref.url, "https://example.com/x")
    }

    func testBlockScalarDescriptionYieldsNoAbstract() {
        let md = "---\ndescription: >\n  folded first line\n  folded second line\ntitle: T\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.title, "T")
        XCTAssertNil(ref.abstract, "unsupported block scalar contributes nothing")
    }

    func testBlockScalarWithModifiersConsumed() {
        let md = "---\ndescription: |2-\n    kept out\ntitle: T\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.title, "T")
        XCTAssertNil(ref.abstract)
    }

    // MARK: Source / type

    func testNonHTTPSourceIsIgnored() {
        let md = "---\nsource: file:///Users/x/doc.pdf\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertNil(ref.url)
        XCTAssertNil(ref.siteName)
        XCTAssertEqual(ref.referenceType, .markdown)
    }

    // MARK: Dates (spec §1 / codex finding 13)

    func testDateVariants() {
        func parseWith(published: String) -> Reference {
            MarkdownImporter.parse("---\npublished: \(published)\n---\nB", filename: "f")
        }
        XCTAssertEqual(parseWith(published: "2026").year, 2026)
        XCTAssertNil(parseWith(published: "2026").issuedMonth)
        XCTAssertEqual(parseWith(published: "2026-06").issuedMonth, 6)
        XCTAssertNil(parseWith(published: "2026-06").issuedDay)
        XCTAssertEqual(parseWith(published: "2024-02-29").issuedDay, 29, "leap day valid")
        XCTAssertNil(parseWith(published: "2025-02-31").year, "calendar-invalid rejected")
        XCTAssertNil(parseWith(published: "2025-01-0199").year, "digit continuation rejected")
        XCTAssertNil(parseWith(published: "garbage").year)
        XCTAssertEqual(parseWith(published: "2026-07-09T10:00:00").issuedDay, 9, "datetime truncates at T")
    }

    func testCreatedDatetimeTruncatesToDate() {
        let md = "---\ncreated: 2026-07-09T10:00:00\n---\nB"
        XCTAssertEqual(MarkdownImporter.parse(md, filename: "f").accessedDate, "2026-07-09")
    }

    func testTagsAreIgnored() {
        let md = "---\ntags:\n  - clippings\n  - ml\n---\nBody"
        let ref = MarkdownImporter.parse(md, filename: "f")
        XCTAssertEqual(ref.decodedWebContent?.body, "Body")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter MarkdownImporterTests 2>&1 | tail -10`
Expected: FAIL — fixture/url/date assertions (stub `makeReference` ignores fields).

- [ ] **Step 3: Implement** — replace the `makeReference` stub and add helpers:

```swift
    // MARK: - Field mapping

    private static func makeReference(
        title: String, fields: [String: FrontmatterValue], body: String
    ) -> Reference {
        var url: String?
        var siteName: String?
        if let source = scalar(fields["source"]),
           let parsed = URL(string: source),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           parsed.host != nil {
            url = source
            siteName = parsed.host
        }

        let published = scalar(fields["published"]).flatMap(parseDateParts)
        let created = scalar(fields["created"]).flatMap(parseDateParts)
        let accessedDate = created.flatMap { parts -> String? in
            guard let m = parts.month, let d = parts.day else { return nil }
            return String(format: "%04d-%02d-%02d", parts.year, m, d)
        }

        return Reference(
            title: title,
            authors: authorList(fields["author"]),
            year: published?.year,
            url: url,
            abstract: scalar(fields["description"]),
            webContent: Reference.encodeWebContent(body, format: .markdown),
            siteName: siteName,
            referenceType: url != nil ? .webpage : .markdown,
            accessedDate: accessedDate,
            issuedMonth: published?.month,
            issuedDay: published?.day
        )
    }

    // MARK: Authors

    private static func authorList(_ value: FrontmatterValue?) -> [AuthorName] {
        let entries: [String]
        switch value {
        case .list(let items):
            entries = items.map(unquote)
        case .scalar(let raw):
            let unquoted = unquote(raw)
            if unquoted.hasPrefix("["), unquoted.hasSuffix("]") {
                entries = splitFlowList(String(unquoted.dropFirst().dropLast()))
            } else {
                entries = [unquoted]
            }
        case nil:
            return []
        }
        return entries
            .map(stripWikiLink)
            .filter { !$0.isEmpty }
            .map(AuthorName.parse)
    }

    /// `[[Jane Doe]]` → `Jane Doe` (Obsidian wiki-link wrapper).
    static func stripWikiLink(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[["), s.hasSuffix("]]"), s.count >= 4 {
            s = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Split a flow-list interior on top-level commas. Tracks quote, escape,
    /// AND bracket depth so `"Smith, John"` and `[a, b]` nested inside an
    /// element never split it.
    static func splitFlowList(_ interior: String) -> [String] {
        var elements: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        var depth = 0
        for ch in interior {
            if escaped { current.append(ch); escaped = false; continue }
            if let q = quote {
                if ch == "\\", q == "\"" { current.append(ch); escaped = true; continue }
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch; current.append(ch)
            case "[", "{":
                depth += 1; current.append(ch)
            case "]", "}":
                depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0:
                elements.append(current); current = ""
            default:
                current.append(ch)
            }
        }
        elements.append(current)
        return elements
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    // MARK: Dates

    /// Accepts `YYYY`, `YYYY-MM`, `YYYY-MM-DD` (calendar-validated, fixed
    /// Gregorian). A datetime suffix is allowed only after `T` or
    /// whitespace; any other trailing characters reject the value.
    static func parseDateParts(_ raw: String) -> (year: Int, month: Int?, day: Int?)? {
        let token = raw.split(whereSeparator: { $0 == "T" || $0.isWhitespace })
            .first.map(String.init) ?? ""
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        func int(_ s: Substring, width: Int) -> Int? {
            guard s.count == width, s.allSatisfy(\.isNumber) else { return nil }
            return Int(s)
        }
        switch parts.count {
        case 1:
            guard let y = int(parts[0], width: 4) else { return nil }
            return (y, nil, nil)
        case 2:
            guard let y = int(parts[0], width: 4), let m = int(parts[1], width: 2),
                  (1...12).contains(m) else { return nil }
            return (y, m, nil)
        case 3:
            guard let y = int(parts[0], width: 4), let m = int(parts[1], width: 2),
                  let d = int(parts[2], width: 2) else { return nil }
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = d
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard comps.isValidDate(in: calendar) else { return nil }
            return (y, m, d)
        default:
            return nil
        }
    }
```

- [ ] **Step 4: Run tests** — `swift test --filter MarkdownImporterTests 2>&1 | tail -5` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCore/Services/MarkdownImporter.swift Tests/RubienCoreTests/MarkdownImporterTests.swift
git commit -m "feat(core): MarkdownImporter clipper field mapping (authors, dates, source)"
```

---

### Task 7: Fill-only merge policy + FTS integration

**Files:**
- Modify: `Sources/RubienCore/Database/AppDatabase.swift` (`batchImportReferences` at ~1539–1603; new merge function near `mergedReference` at ~2256)
- Test: `Tests/RubienCoreTests/MarkdownImportMergeTests.swift` (create)

**Interfaces:**
- Consumes: `MarkdownImporter.parse` (Tasks 5–6).
- Produces: `ImportMergePolicy` enum; `batchImportReferences(_:stamping:pdfFilenames:mergePolicy:) -> (count: Int, ids: [Int64])` with `.standard` default (existing call sites unchanged). CLI (Tasks 8–9) and app (Task 12) pass `.markdownFillOnly`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RubienCoreTests/MarkdownImportMergeTests.swift`:

```swift
import XCTest
import GRDB
@testable import RubienCore

final class MarkdownImportMergeTests: XCTestCase {

    private func makeDB() throws -> AppDatabase { try AppDatabase(DatabaseQueue()) }

    func testURLMatchNeverOverwritesCuratedTitle() throws {
        let db = try makeDB()
        var curated = Reference(
            title: "Curated Title",
            url: "https://example.com/post",
            webContent: Reference.encodeWebContent("short", format: .markdown),
            referenceType: .webpage
        )
        _ = try db.saveReference(&curated)

        // Frontmatter-less re-import: title is the filename fallback.
        let incoming = MarkdownImporter.parse(
            "---\nsource: https://example.com/post\n---\nA much longer body than short.",
            filename: "some-filename"
        )
        let result = try db.batchImportReferences([incoming], mergePolicy: .markdownFillOnly)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.ids, [curated.id!], "merged, not duplicated")

        let merged = try db.fetchReferences(ids: [curated.id!]).first!
        XCTAssertEqual(merged.title, "Curated Title")
        XCTAssertEqual(merged.decodedWebContent?.body, "A much longer body than short.",
                       "longest content wins")
    }

    func testFillOnlyFieldsPopulateWhenEmpty() throws {
        let db = try makeDB()
        var bare = Reference(title: "Bare", url: "https://example.com/p2", referenceType: .webpage)
        _ = try db.saveReference(&bare)

        let md = """
        ---
        source: https://example.com/p2
        author: Jane Doe
        published: 2026-01-02
        description: An abstract.
        ---
        Body
        """
        _ = try db.batchImportReferences(
            [MarkdownImporter.parse(md, filename: "f")], mergePolicy: .markdownFillOnly
        )
        let merged = try db.fetchReferences(ids: [bare.id!]).first!
        XCTAssertEqual(merged.authors.first?.displayName, "Jane Doe")
        XCTAssertEqual(merged.year, 2026)
        XCTAssertEqual(merged.abstract, "An abstract.")
    }

    func testFillOnlyFieldsNeverOverwrite() throws {
        let db = try makeDB()
        var curated = Reference(
            title: "T", authors: [AuthorName(given: "Ada", family: "Lovelace")],
            year: 1815, url: "https://example.com/p3",
            abstract: "Curated abstract.", referenceType: .webpage
        )
        _ = try db.saveReference(&curated)

        let md = "---\nsource: https://example.com/p3\nauthor: Somebody Else\npublished: 2020-01-01\ndescription: New abstract.\n---\nB"
        _ = try db.batchImportReferences(
            [MarkdownImporter.parse(md, filename: "f")], mergePolicy: .markdownFillOnly
        )
        let merged = try db.fetchReferences(ids: [curated.id!]).first!
        XCTAssertEqual(merged.authors.first?.family, "Lovelace")
        XCTAssertEqual(merged.year, 1815)
        XCTAssertEqual(merged.abstract, "Curated abstract.")
    }

    func testURLLessNotesAlwaysInsert() throws {
        let db = try makeDB()
        let note = MarkdownImporter.parse("Body one", filename: "Meeting notes")
        _ = try db.batchImportReferences([note], mergePolicy: .markdownFillOnly)
        _ = try db.batchImportReferences([note], mergePolicy: .markdownFillOnly)
        let count = try db.dbWriter.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM reference WHERE title = 'Meeting notes'") ?? 0
        }
        XCTAssertEqual(count, 2, "no match key → duplicate is the documented v1 behavior")
    }

    /// Spec §10: prove FTS reaches imported markdown bodies. Single
    /// alphanumeric token (hyphens would tokenize into a phrase and couple
    /// the test to punctuation behavior).
    func testImportedBodyIsFTSSearchable() throws {
        let db = try makeDB()
        XCTAssertTrue(try db.searchReferences(query: "zanzibarquokka77").isEmpty,
                      "token must not pre-exist")
        let note = MarkdownImporter.parse(
            "The zanzibarquokka77 theorem holds.", filename: "unique-note"
        )
        let imported = try db.batchImportReferences([note], mergePolicy: .markdownFillOnly)
        let hits = try db.searchReferences(query: "zanzibarquokka77")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, imported.ids.first)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter MarkdownImportMergeTests 2>&1 | tail -10`
Expected: FAIL — no `mergePolicy:` parameter.

- [ ] **Step 3: Implement**

In `AppDatabase.swift`:

```swift
/// How `batchImportReferences` reconciles an incoming reference with a
/// dedup match. `.standard` is the historical bib/ris behavior
/// (`mergedReference` — incoming metadata preferred). `.markdownFillOnly`
/// protects curated data from re-imported markdown files (spec §8):
/// metadata fills empty fields only; content stays longest-wins.
public enum ImportMergePolicy: Sendable {
    case standard
    case markdownFillOnly
}
```

Extend the tuple-returning overload's signature (append with a default —
existing call sites compile unchanged):

```swift
public func batchImportReferences(
    _ references: [Reference],
    stamping target: ZoteroImportPropertyTarget? = nil,
    pdfFilenames: [String?]? = nil,
    mergePolicy: ImportMergePolicy = .standard
) throws -> (count: Int, ids: [Int64]) {
```

and switch the merge line inside the loop:

```swift
existing = switch mergePolicy {
case .standard:         mergedReference(existing: existing, incoming: ref)
case .markdownFillOnly: markdownFillMergedReference(existing: existing, incoming: ref)
}
```

Add next to `mergedReference` (~line 2256):

```swift
/// Spec §8 fill-only merge for markdown imports: never overwrite curated
/// metadata; body stays longest-wins (annotation-anchor-safe).
private func markdownFillMergedReference(existing: Reference, incoming: Reference) -> Reference {
    func fillIfEmpty(_ incoming: String?, existing: String?) -> String? {
        if let e = existing?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            return existing
        }
        let c = incoming?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (c?.isEmpty == false) ? incoming : existing
    }
    func preferredLongest(_ incoming: String?, over existing: String?) -> String? {
        let lhs = incoming?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = existing?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (lhs?.isEmpty == false ? lhs : nil, rhs?.isEmpty == false ? rhs : nil) {
        case let (l?, r?): return l.count >= r.count ? incoming : existing
        case (.some, nil): return incoming
        case (nil, .some): return existing
        default: return nil
        }
    }

    var merged = existing
    merged.title = existing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? incoming.title : existing.title
    merged.authors = existing.authors.isEmpty ? incoming.authors : existing.authors
    merged.abstract = fillIfEmpty(incoming.abstract, existing: existing.abstract)
    merged.year = existing.year ?? incoming.year
    merged.issuedMonth = existing.issuedMonth ?? incoming.issuedMonth
    merged.issuedDay = existing.issuedDay ?? incoming.issuedDay
    merged.accessedDate = fillIfEmpty(incoming.accessedDate, existing: existing.accessedDate)
    merged.siteName = fillIfEmpty(incoming.siteName, existing: existing.siteName)
    merged.webContent = preferredLongest(incoming.webContent, over: existing.webContent)
    return merged
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MarkdownImportMergeTests 2>&1 | tail -5` → PASS
Run: `swift test --filter RubienCoreTests 2>&1 | tail -5` → PASS (whole target; existing import suites must be untouched by the default `.standard`)

- [ ] **Step 5: Commit + phase gate**

```bash
git add Sources/RubienCore Tests/RubienCoreTests
git commit -m "feat(core): fill-only merge policy for markdown imports + FTS coverage"
```

**Phase 1 gate:** run the repo review cycle (codex-rescue on `git diff main...HEAD`, then `/simplify`) before starting Phase 2.

---

## Phase 2 — CLI

### Task 8: `import` accepts `.md` files and `--format md` stdin

**Files:**
- Modify: `Sources/RubienCLI/RubienCLI.swift` (`Import.run()` ext switch at ~lines 994–1007; stdin guard + format help at ~948, 972–975)
- Test: `Tests/RubienCLITests/SwiftLibCLITests.swift` (append to the `RubienCLITests` class; reuse its `runCLI` helper and `RUBIEN_LIBRARY_ROOT` isolation)

**Interfaces:**
- Consumes: `MarkdownImporter.parse`, `batchImportReferences(_:stamping:pdfFilenames:mergePolicy:)`.
- Produces: `rubien-cli import note.md` and `import - --format md`, JSON `{"imported": "1", "file": <path>}` (existing shape); JSON errors for unreadable/non-UTF-8 md files.

- [ ] **Step 1: Write the failing tests** (append inside the `RubienCLITests` class; write fixtures under `testLibraryRoot`)

If `runCLI` has no `stdin:` parameter yet, add an overload next to it that
pipes a string through `process.standardInput` (a `Pipe` whose write handle
is written then closed before `waitUntilExit`), leaving the existing
signature untouched.

```swift
    func testImportMarkdownFile() throws {
        // Sentinel of a different type so the --type filters below can't
        // pass vacuously.
        let addResult = try runCLI(["add", "--title", "Sentinel Article"])
        XCTAssertEqual(addResult.exitCode, 0, addResult.stderr)

        let md = """
        ---
        title: "Clip Title"
        source: "https://example.com/clip"
        published: 2026-06-13
        ---
        Clip body.
        """
        let file = testLibraryRoot.appendingPathComponent("clip.md")
        try md.write(to: file, atomically: true, encoding: .utf8)

        let result = try runCLI(["import", file.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1")

        let list = try runCLI(["list", "--type", "Web Page"])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 1, "only the clip is a Web Page; sentinel filtered out")
        XCTAssertEqual(rows.first?["title"] as? String, "Clip Title")
        XCTAssertEqual(rows.first?["referenceType"] as? String, "Web Page")
    }

    func testImportMarkdownStdinTitlesUntitled() throws {
        let result = try runCLI(["import", "-", "--format", "md"], stdin: "no frontmatter body")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let list = try runCLI(["list", "--type", "Markdown"])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        XCTAssertTrue(list.stdout.contains("Untitled"))
    }

    func testStdinWithoutFormatMentionsMd() throws {
        let result = try runCLI(["import", "-"], stdin: "x")
        XCTAssertNotEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("md"), "error text must list md as a valid format: \(combined)")
    }

    func testImportMarkdownNoteGetsMarkdownType() throws {
        _ = try runCLI(["add", "--title", "Sentinel Article"])
        let file = testLibraryRoot.appendingPathComponent("note.md")
        try "# Plain Note\nBody".write(to: file, atomically: true, encoding: .utf8)
        let imported = try runCLI(["import", file.path])
        XCTAssertEqual(imported.exitCode, 0, imported.stderr)

        let list = try runCLI(["list", "--type", "Markdown"])
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["title"] as? String, "Plain Note")
    }

    func testImportNonUTF8MarkdownEmitsJSONError() throws {
        let file = testLibraryRoot.appendingPathComponent("latin1.md")
        let latin1 = Data([0x23, 0x20, 0xE9, 0xE8, 0xFF])   // "# " + Latin-1 bytes, invalid UTF-8
        try latin1.write(to: file)
        let result = try runCLI(["import", file.path])
        XCTAssertNotEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("error"), "JSON error contract expected: \(combined)")
        XCTAssertTrue(combined.contains("latin1.md"), "error names the file")
    }

    /// Spec §10 export mappings: Markdown → BibTeX @misc, RIS TY GEN.
    func testMarkdownTypeExportMappings() throws {
        let file = testLibraryRoot.appendingPathComponent("note.md")
        try "# Export Me\nBody".write(to: file, atomically: true, encoding: .utf8)
        let imported = try runCLI(["import", file.path])
        XCTAssertEqual(imported.exitCode, 0, imported.stderr)

        let bib = try runCLI(["export", "--format", "bibtex"])
        XCTAssertEqual(bib.exitCode, 0, bib.stderr)
        XCTAssertTrue(bib.stdout.contains("@misc{"), bib.stdout)

        let ris = try runCLI(["export", "--format", "ris"])
        XCTAssertEqual(ris.exitCode, 0, ris.stderr)
        XCTAssertTrue(ris.stdout.contains("TY  - GEN"), ris.stdout)
    }
```

Note on `list` JSON: if `list --type` output turns out not to be a bare
array (check the existing list tests in this file for the actual shape),
adapt the decode lines to that shape — the assertions to keep are the exact
count, the title, and the `referenceType` value.

- [ ] **Step 2: Run to verify failure**

Build first (the CLI tests exec the built binary): `swift build --product rubien-cli`
Run: `swift test --filter RubienCLITests 2>&1 | tail -10`
Expected: the new tests FAIL — "Unsupported file format: .md". Confirm a non-zero executed-test count.

- [ ] **Step 3: Implement**

In `Import.run()`:

1. Stdin guard (~972): change the error to
   `"--format (bib, ris, or md) is required when reading from stdin"`.
2. For `.md` paths, the file-read errors must honor the JSON contract.
   Wrap the existing metadata/read section (~984–992) so md (and only new
   md-specific failures — leave bib/ris behavior untouched) reports via
   `printJSONError`; simplest: after computing `ext`, branch:

```swift
} else {
    let url = URL(fileURLWithPath: file)
    ext = format?.lowercased() ?? url.pathExtension.lowercased()
    do {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? UInt64, size > 50 * 1024 * 1024 {
            printJSONError("File exceeds 50 MB limit (\(size / 1024 / 1024) MB)")
            throw ExitCode.failure
        }
        content = try String(contentsOf: url, encoding: .utf8)
    } catch let error as ExitCode {
        throw error
    } catch {
        printJSONError("Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        throw ExitCode.failure
    }
}
```

3. Replace the format switch tail (~994–1007):

```swift
var refs: [Reference]
var mergePolicy: ImportMergePolicy = .standard
switch ext {
case "bib", "bibtex":
    refs = BibTeXImporter.parse(content)
case "ris":
    refs = RISImporter.parse(content)
case "md", "markdown":
    let basename = file == "-"
        ? nil
        : URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    refs = [MarkdownImporter.parse(content, filename: basename)]
    mergePolicy = .markdownFillOnly
default:
    printJSONError("Unsupported file format: .\(ext). Use .bib, .ris, or .md")
    throw ExitCode.failure
}

let count = try AppDatabase.shared.batchImportReferences(refs, mergePolicy: mergePolicy).count
notifyLibraryChanged()
printJSON(["imported": "\(count)", "file": file])
```

4. Update the `--format` help (~948) to `"Format hint when reading from stdin: bib, ris, md"` and the `@Argument` help (~945) to mention `.md`.

- [ ] **Step 4: Run tests**

Run: `swift build --product rubien-cli && swift test --filter RubienCLITests 2>&1 | tail -5` → PASS (confirm executed-test count > 0)

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCLI Tests/RubienCLITests
git commit -m "feat(cli): import .md files and --format md stdin with JSON error contract"
```

---

### Task 9: Folder routing + markdown folder import with stamping

**Files:**
- Modify: `Sources/RubienCLI/RubienCLI.swift` (folder branch at ~957–965; new `runMarkdownFolderImport` next to `runZoteroFolderImport` at ~1010)
- Test: `Tests/RubienCLITests/SwiftLibCLITests.swift` (append to the `RubienCLITests` class)

**Interfaces:**
- Consumes: `MarkdownImporter.parse`, `batchImportReferences(..., stamping:mergePolicy:)`, `PropertyDefinition.tagsPropertyName`, `ZoteroImportPropertyTarget`.
- Produces: folder routing per spec §5; JSON envelope `{"imported", "failed", "property", "value", "file"}`.

- [ ] **Step 1: Write the failing tests** (append)

```swift
    private func makeClippingsFolder(_ name: String, files: [String: String]) throws -> URL {
        let dir = testLibraryRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (filename, content) in files {
            try content.write(
                to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8
            )
        }
        return dir
    }

    /// Extract reference titles→tag values via `properties --list` /
    /// `get`: adapt to this file's existing helpers for reading a
    /// reference's Tags (several sibling tests already assert tag values —
    /// follow their exact query pattern).
    func testImportMarkdownFolderStampsTagsWithBasename() throws {
        let dir = try makeClippingsFolder("Clippings", files: [
            "a.md": "# Note A\nBody A",
            "b.md": "# Note B\nBody B",
        ])
        let result = try runCLI(["import", dir.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "2")
        XCTAssertEqual(obj["failed"], "")
        XCTAssertEqual(obj["property"], "Tags")
        XCTAssertEqual(obj["value"], "Clippings")

        // Stamping must be REAL, not just reported: both references carry
        // the "Clippings" tag. Follow the sibling tag-assert pattern.
        let list = try runCLI(["list", "--tag", "Clippings"])
        XCTAssertEqual(list.exitCode, 0, list.stderr)
        XCTAssertTrue(list.stdout.contains("Note A"))
        XCTAssertTrue(list.stdout.contains("Note B"))
    }

    func testImportMarkdownFolderPropertyValueOverride() throws {
        let dir = try makeClippingsFolder("Clips2", files: ["c.md": "# Note C\nBody"])
        let result = try runCLI([
            "import", dir.path, "--property", "Tags", "--value", "custom-tag",
        ])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["value"], "custom-tag")
        let list = try runCLI(["list", "--tag", "custom-tag"])
        XCTAssertTrue(list.stdout.contains("Note C"))
    }

    func testImportMarkdownFolderReportsFailedFiles() throws {
        let dir = try makeClippingsFolder("Mixed2", files: ["good.md": "# Good\nBody"])
        let bad = Data([0x23, 0x20, 0xE9, 0xE8, 0xFF])   // invalid UTF-8
        try bad.write(to: dir.appendingPathComponent("bad.md"))

        let result = try runCLI(["import", dir.path])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1", "valid file still imports")
        XCTAssertEqual(obj["failed"], "bad.md")
    }

    func testAmbiguousFolderErrorsAndFormatForces() throws {
        let dir = try makeClippingsFolder("Ambiguous", files: [
            "refs.bib": "@article{k, title={T}, year={2020}}",
            "note.md": "# N\nB",
        ])
        let ambiguous = try runCLI(["import", dir.path])
        XCTAssertNotEqual(ambiguous.exitCode, 0)
        let combined = ambiguous.stdout + ambiguous.stderr
        XCTAssertTrue(combined.contains("Ambiguous folder"), combined)

        let forced = try runCLI(["import", dir.path, "--format", "md"])
        XCTAssertEqual(forced.exitCode, 0, forced.stderr)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(forced.stdout.utf8)) as? [String: String]
        )
        XCTAssertEqual(obj["imported"], "1")
    }

    func testEmptyFolderErrors() throws {
        let dir = try makeClippingsFolder("Empty", files: [:])
        let result = try runCLI(["import", dir.path])
        XCTAssertNotEqual(result.exitCode, 0)
    }
```

(If `list --tag` is not an existing flag, use whatever tag-filter/read
mechanism the sibling tests use — e.g. `properties` value listing or `get`
on the imported id. The invariant under test: the stamped value is stored,
not merely echoed.)

- [ ] **Step 2: Run to verify failure**

Run: `swift build --product rubien-cli && swift test --filter RubienCLITests 2>&1 | tail -10`
Expected: new tests FAIL (folder always routes to Zotero and errors on the missing `.bib`).

- [ ] **Step 3: Implement**

Replace the folder branch in `Import.run()` (~957–965):

```swift
// Folder path → route by contents (spec §5).
if file != "-" {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: file, isDirectory: &isDir), isDir.boolValue {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: file)) ?? []
        let hasBib = entries.contains { $0.lowercased().hasSuffix(".bib") }
        let hasMD = entries.contains { $0.lowercased().hasSuffix(".md") }

        if let forced = format?.lowercased() {
            switch forced {
            case "bib", "bibtex":
                guard hasBib else {
                    printJSONError("No .bib files found in folder")
                    throw ExitCode.failure
                }
                try runZoteroFolderImport(folderPath: file)
            case "md", "markdown":
                guard hasMD else {
                    printJSONError("No .md files found in folder")
                    throw ExitCode.failure
                }
                try runMarkdownFolderImport(folderPath: file)
            default:
                printJSONError("Unsupported folder format: \(forced). Use bib or md.")
                throw ExitCode.failure
            }
            return
        }

        switch (hasBib, hasMD) {
        case (true, true):
            printJSONError("Ambiguous folder: contains both .bib and .md. Pass --format bib or --format md to choose.")
            throw ExitCode.failure
        case (true, false):
            try runZoteroFolderImport(folderPath: file)
            return
        case (false, true):
            try runMarkdownFolderImport(folderPath: file)
            return
        case (false, false):
            printJSONError("No importable files found (expected .bib or .md)")
            throw ExitCode.failure
        }
    }
}
```

Add below `runZoteroFolderImport`:

```swift
private func runMarkdownFolderImport(folderPath: String) throws {
    let folderURL = URL(fileURLWithPath: folderPath)
    let db = AppDatabase.shared

    let propertyName = property ?? PropertyDefinition.tagsPropertyName
    let stampValue = value ?? folderURL.lastPathComponent
    guard let propDef = try db.findPropertyDefinition(byName: propertyName),
          let propId = propDef.id else {
        printJSONError("Property not found: '\(propertyName)'")
        throw ExitCode.failure
    }

    let mdFiles = ((try? FileManager.default.contentsOfDirectory(
        at: folderURL, includingPropertiesForKeys: [.fileSizeKey]
    )) ?? [])
        .filter { $0.pathExtension.lowercased() == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var refs: [Reference] = []
    var failed: [String] = []
    for url in mdFiles {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 50 * 1024 * 1024 else { failed.append(url.lastPathComponent); continue }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            failed.append(url.lastPathComponent); continue
        }
        refs.append(MarkdownImporter.parse(
            content, filename: url.deletingPathExtension().lastPathComponent
        ))
    }

    let result = try db.batchImportReferences(
        refs,
        stamping: ZoteroImportPropertyTarget(propertyId: propId, value: stampValue),
        mergePolicy: .markdownFillOnly
    )
    notifyLibraryChanged()
    printJSON([
        "imported": "\(result.count)",
        "failed": failed.joined(separator: ", "),
        "property": propertyName,
        "value": stampValue,
        "file": folderPath,
    ])
}
```

Update the `Import` abstract and `@Option property/value` help strings to
say "Zotero or markdown folder" instead of Zotero-only.

- [ ] **Step 4: Run tests** — `swift build --product rubien-cli && swift test --filter RubienCLITests 2>&1 | tail -5` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/RubienCLI Tests/RubienCLITests
git commit -m "feat(cli): markdown folder import with property stamping and explicit routing"
```

---

### Task 10: Documentation sweep

**Files:**
- Modify: `Docs/CLI-Reference.md` (import section + full reference-type list)
- Modify: `Docs/Sync-Runbook.md` (six-type/six-option mentions)

**Interfaces:** none (docs). (The spec's migration-precedent wording was already corrected to v3 when this plan was authored — no spec edits here.)

- [ ] **Step 1: `Docs/CLI-Reference.md`** — document in the `import` section: `.md` single-file import (frontmatter mapping table, fill-only merge, URL-less re-import duplicates), `--format md` stdin, folder routing rules verbatim from spec §5 including the ambiguity error, stamping defaults (`Tags` = folder basename). Replace ANY reference-type enumeration in the doc with the exact current seven: `Journal Article, Conference Paper, Book, Thesis, Web Page, Markdown, Other` (the doc may still carry a stale pre-v3 21-type list — replace it wholesale, don't just append).

- [ ] **Step 2: `Docs/Sync-Runbook.md`** — `grep -n 'six\|Six\|6 option\|Journal Article' Docs/Sync-Runbook.md` and update any description of the Type option set to the seven-option reality, noting the v6 append + remote-apply healing in one sentence each.

- [ ] **Step 3: Verify** — `grep -rn 'Magazine Article\|Preprint\|Blog Post' Docs/CLI-Reference.md` → no hits (stale list gone); `grep -c 'Markdown' Docs/CLI-Reference.md` → ≥ 3.

- [ ] **Step 4: Commit + phase gate**

```bash
git add Docs/CLI-Reference.md Docs/Sync-Runbook.md
git commit -m "docs: markdown import CLI reference; seven-type sweep"
```

**Phase 2 gate:** codex-rescue + `/simplify` on the phase diff.

---

## Phase 3 — App (Mac target; no automated tests — manual verification, see Task 12 Step 5)

### Task 11: Multi-select open panel + button strings

**Files:**
- Modify: `Sources/Rubien/Helpers/OpenPanelPicker.swift`
- Modify: `Sources/Rubien/Views/ContentView.swift` (~919–924: label/help)
- Modify: `Sources/Rubien/Resources/en.lproj/Localizable.strings` (line 71)

**Interfaces:**
- Produces: `@MainActor static func pickImportableFiles() -> [URL]` (empty = cancelled). Task 12 consumes it.

- [ ] **Step 1: Implement the picker** — add to `OpenPanelPicker` (every sibling picker is `@MainActor`; this one must be too — `configuredPanel`/`NSOpenPanel` are main-actor):

```swift
/// Multi-select picker for the Import PDF/Markdown toolbar action.
/// Returns [] when cancelled.
@MainActor
static func pickImportableFiles() -> [URL] {
    let panel = configuredPanel(
        title: String(localized: "Import PDF/Markdown", bundle: .module),
        prompt: String(localized: "Import", bundle: .module),
        allowedContentTypes: [.pdf, type(forExtension: "md", fallback: .plainText)]
    )
    panel.allowsMultipleSelection = true
    return panel.runModal() == .OK ? panel.urls : []
}
```

- [ ] **Step 2: Update strings** — `en.lproj/Localizable.strings` line 71:

```
"content.toolbar.importPDFAuto" = "Import PDF/Markdown";
```

In `ContentView.swift` ~924 change the `.help` literal to
`"Import PDFs or markdown notes; PDF metadata is auto-filled when possible"`
(and update the matching key in `Localizable.strings` if the old literal
has an entry — check with `grep -n "Import a PDF and auto-fill" Sources/Rubien/Resources/en.lproj/Localizable.strings`).

- [ ] **Step 3: Build** — `swift build 2>&1 | tail -3` → succeeds. (The button still calls the old single-PDF flow until Task 12; that's fine — this commit is UI-surface only and must not change behavior.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Rubien
git commit -m "feat(app): Import PDF/Markdown panel (multi-select) and toolbar strings"
```

---

### Task 12: Batch import coordinator + detail-view gate mirror

**Files:**
- Modify: `Sources/Rubien/Views/ContentView.swift` (`importPDFWithMetadata` at ~1420–1472; `finishPDFImport` at ~1474; button action at ~920; `queueResolutionResult` stays untouched at ~1648)
- Modify: `Sources/Rubien/Views/ReferenceDetailView.swift` (`canOpenWebReader` at ~1230–1232)

**Interfaces:**
- Consumes: `OpenPanelPicker.pickImportableFiles()` (Task 11), `MarkdownImporter.parse`, `batchImportReferences(..., mergePolicy: .markdownFillOnly)` (Task 7), `viewModel.persistMetadataResolution(_:options:) -> MetadataPersistenceResult?` (existing — the persistence-only core that `queueResolutionResult` wraps with UI side effects).
- Produces: `importFilesWithMetadata()` (button action), `importSinglePDF(url:) async -> PDFImportOutcome` (per-file, NO global-state mutation), `PDFImportOutcome` enum.

**Key design point (codex findings 4/5):** `queueResolutionResult` mutates
`isImporting`/`importProgress` and schedules delayed clears — calling it
per file would make a batch look idle after the first PDF and let stale
timers erase the final summary. The batch path therefore calls
`viewModel.persistMetadataResolution` directly (persistence only) and the
coordinator owns every UI mutation. `queueResolutionResult` keeps its other
call sites unchanged.

- [ ] **Step 1: Mirror the reader gate** — `ReferenceDetailView.swift` ~1231:

```swift
private var canOpenWebReader: Bool {
    hasStoredWebContent
        || (reference.referenceType == .webpage && resolvedWebReaderURLString != nil)
}
```

- [ ] **Step 2: Restructure the import flow** — in `ContentView.swift` (all of the following live inside the ContentView struct and are implicitly `@MainActor`):

1. Add the outcome type near the other private types:

```swift
private enum PDFImportOutcome {
    case imported(title: String)
    case queued(MetadataIntake)
    case failed(String)
}
```

2. Change the button action (~920) from `importPDFWithMetadata()` to `importFilesWithMetadata()`.
3. Rename `importPDFWithMetadata()` → `importFilesWithMetadata()` with this body (the coordinator owns ALL batch state):

```swift
private func importFilesWithMetadata() {
    let urls = OpenPanelPicker.pickImportableFiles()
    guard !urls.isEmpty else { return }
    let mdURLs = urls.filter { $0.pathExtension.lowercased() == "md" }
    let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }

    viewModel.isImporting = true
    viewModel.importProgress = String(localized: "content.import.progress.importingPDF", bundle: .module)

    Task { @MainActor in
        var summary: [String] = []
        var firstIntake: MetadataIntake?

        // Markdown: instant local batch (spec §4). 50 MB / UTF-8 guards per file.
        if !mdURLs.isEmpty {
            var refs: [Reference] = []
            var failed: [String] = []
            for url in mdURLs {
                // Sandboxed app: same security-scoped access dance as
                // viewModel.importBibTeX(from:).
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 50 * 1024 * 1024,
                      let content = try? String(contentsOf: url, encoding: .utf8) else {
                    failed.append(url.lastPathComponent)
                    continue
                }
                refs.append(MarkdownImporter.parse(
                    content, filename: url.deletingPathExtension().lastPathComponent
                ))
            }
            if !refs.isEmpty {
                do {
                    let result = try viewModel.db.batchImportReferences(
                        refs, mergePolicy: .markdownFillOnly
                    )
                    selectedId = result.ids.last
                    let fmt = String(localized: "Imported %d markdown file(s)", bundle: .module)
                    summary.append(String(format: fmt, result.count))
                    // No explicit reload: the list refreshes via observation,
                    // same as viewModel.importBibTeX(from:).
                } catch {
                    summary.append("Markdown import failed: \(error.localizedDescription)")
                }
            }
            if !failed.isEmpty {
                summary.append(
                    String(format: String(localized: "Could not read: %@", bundle: .module),
                           failed.joined(separator: ", "))
                )
            }
        }

        // PDFs: sequential, one metadata resolution at a time (spec §4).
        for (index, url) in pdfURLs.enumerated() {
            if pdfURLs.count > 1 {
                viewModel.importProgress = "\(url.lastPathComponent) (\(index + 1)/\(pdfURLs.count))…"
            }
            switch await importSinglePDF(url: url) {
            case .imported(let title):
                let fmt = String(localized: "Imported: %@", bundle: .module)
                summary.append(String(format: fmt, title))
            case .queued(let intake):
                if firstIntake == nil { firstIntake = intake }
                summary.append(String(localized: "Couldn't auto-verify — added to the pending queue", bundle: .module))
            case .failed(let message):
                summary.append(message)
            }
        }

        viewModel.isImporting = false
        viewModel.importProgress = summary.isEmpty ? nil : summary.joined(separator: " · ")
        if let intake = firstIntake {
            showPendingQueueNotice(for: intake, message: nil)
        }
        // Auto-clear the toast like viewModel.importBibTeX(from:) does.
        if !summary.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if !viewModel.isImporting {
                    viewModel.importProgress = nil
                }
            }
        }
    }
}
```

4. Extract today's per-PDF body into `importSinglePDF(url:)`. Move the code
   currently inside `importPDFWithMetadata`'s `Task { ... }` with exactly
   these changes — it must NOT touch `viewModel.isImporting` /
   `viewModel.importProgress` and must NOT call `queueResolutionResult`
   (persistence goes through `viewModel.persistMetadataResolution`, the
   same call `queueResolutionResult` wraps at ~line 1653):

```swift
/// Runs the existing single-PDF import + resolution flow for one file.
/// Pure per-file: returns the outcome for the batch summary; never mutates
/// isImporting/importProgress (the coordinator owns those).
private func importSinglePDF(url: URL) async -> PDFImportOutcome {
    do {
        let prepared = try PDFService.prepareImportedPDF(from: url)
        let preparedPDFFilename = prepared.pdfPath
        _ = MetadataResolutionSeed.fromImportedPDF(url: url, extracted: prepared.extracted)

        let resolution = await metadataResolver.resolveImportedPDF(url: url, extracted: prepared.extracted)

        switch resolution {
        case .verified(let envelope):
            let reference = envelope.reference
            finishPDFImport(with: reference, pdfFilename: preparedPDFFilename)
            return .imported(title: reference.title)

        case .candidate, .blocked, .seedOnly, .rejected:
            let persisted = viewModel.persistMetadataResolution(
                resolution,
                options: MetadataPersistenceOptions(
                    sourceKind: .importedPDF,
                    preferredPDFPath: preparedPDFFilename
                )
            )
            switch persisted {
            case .verified(let reference):
                selectedId = reference.id
                return .imported(title: reference.title)
            case .intake(let intake):
                return .queued(intake)
            case .none:
                PDFService.deletePDF(at: preparedPDFFilename)
                let fmt = String(localized: "PDF import failed: %@", bundle: .module)
                return .failed(String(format: fmt, url.lastPathComponent))
            }
        }
    } catch {
        let fmt = String(localized: "PDF import failed: %@", bundle: .module)
        return .failed(String(format: fmt, error.localizedDescription))
    }
}
```

   (Check `persistMetadataResolution`'s actual result cases at
   ~ContentView.swift:1653 — `.verified` / `.intake` / `nil` — and match
   them exactly; if it returns other cases, map anything non-verified,
   non-intake to `.failed`.)

5. Trim `finishPDFImport(with:pdfFilename:message:)` to
   `finishPDFImport(with:pdfFilename:)`: delete its
   `viewModel.isImporting = false` and `viewModel.importProgress = message`
   lines (the coordinator owns those now); keep save/attach/drainer-kick/
   `selectedId` exactly as-is.
6. Check remaining callers: `grep -n "importPDFWithMetadata\|finishPDFImport\|queueResolutionResult" Sources/Rubien/Views/ContentView.swift` — update calls to the renamed functions; `queueResolutionResult` keeps its other call sites (pending-queue re-runs, batch identifier import) untouched.

- [ ] **Step 3: Build** — `swift build 2>&1 | tail -3` → succeeds.

- [ ] **Step 4: Run app-adjacent tests** — `swift test --filter RubienTests 2>&1 | tail -5` → PASS (existing suite only; no new automated app tests — WKWebView tests deadlock the suite).

- [ ] **Step 5: Manual verification (required before commit)** — run the app against a scratch library (`RUBIEN_LIBRARY_ROOT=$(mktemp -d) swift run Rubien`):
  1. Toolbar shows "Import PDF/Markdown"; panel multi-selects `.md` + `.pdf`.
  2. Import 2 `.md` notes (no frontmatter) → both appear, type Markdown, `doc.plaintext` icon.
  3. Double-click a URL-less note → web reader opens, body renders, a highlight saves and survives reopen.
  4. Import a real Obsidian clipping → type Web Page, URL/site filled; open reader.
  5. Import 1 PDF + 1 md in one selection → md lands instantly, PDF resolves after; summary toast lists both; toast clears ~4 s later.
  6. Import a PDF that can't auto-verify → pending-queue notice appears once, after the batch.
  7. Re-import the same clipping → no duplicate row.

- [ ] **Step 6: Commit + phase gate**

```bash
git add Sources/Rubien
git commit -m "feat(app): PDF/Markdown batch import coordinator; content-driven reader gate in detail view"
```

**Phase 3 gate:** codex-rescue + `/simplify` on the phase diff.

---

## Phase 4 — MCP server

### Task 13: `rubien_import` schema + version + tests

**Files:**
- Modify: `mcp-server/src/tools/io.ts` (lines 9–30)
- Modify: `mcp-server/src/server.ts` (SERVER_INFO version at line 14)
- Modify: `mcp-server/package.json` + `mcp-server/package-lock.json` (patch bump)
- Test: `mcp-server/test/import-tool.test.ts` (create)

**Interfaces:** none new — the tool shells to the CLI, which already supports `.md` after Task 9.

- [ ] **Step 1: Write the failing tests**

Create `mcp-server/test/import-tool.test.ts`. Two parts: schema shape, and
**argument forwarding** (the handler must actually pass `format`/`property`/
`value` through to the CLI — mock the runner):

```typescript
import { describe, it, expect, vi } from "vitest";

// Mock the CLI runner BEFORE importing the server so registerIOTools
// captures the mock. Match ../src/toolHelpers.js's actual export names.
vi.mock("../src/toolHelpers.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/toolHelpers.js")>();
  return {
    ...actual,
    runCliAsTool: vi.fn(async (args: string[]) => ({
      content: [{ type: "text", text: JSON.stringify({ echoedArgs: args }) }],
    })),
  };
});

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { buildServer } from "../src/server.js";
import { runCliAsTool } from "../src/toolHelpers.js";

async function connectedClient() {
  const server = buildServer();
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "test", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return client;
}

describe("rubien_import", () => {
  it("advertises md format and folder-neutral stamping descriptions", async () => {
    const client = await connectedClient();
    const tools = await client.listTools();
    const importTool = tools.tools.find((t) => t.name === "rubien_import");
    expect(importTool).toBeDefined();
    const schema = JSON.stringify(importTool!.inputSchema);
    expect(schema).toContain('"md"');
    expect(schema).not.toContain("Zotero folder only");
  });

  it("forwards format/property/value to the CLI", async () => {
    const client = await connectedClient();
    await client.callTool({
      name: "rubien_import",
      arguments: {
        file: "/tmp/Clippings",
        format: "md",
        property: "Tags",
        value: "Clippings",
      },
    });
    expect(vi.mocked(runCliAsTool)).toHaveBeenCalledWith(
      ["import", "/tmp/Clippings", "--format", "md", "--property", "Tags", "--value", "Clippings"],
      expect.anything(),
    );
  });
});
```

(If the `vi.mock` factory conflicts with how `toolHelpers` is structured,
follow the mocking approach used by any existing test that stubs the CLI —
check `test/` siblings first. The invariant: the forwarded argv is asserted
exactly.)

- [ ] **Step 2: Run to verify failure**

Run: `cd mcp-server && npm test -- import-tool 2>&1 | tail -10`
Expected: FAIL — schema lacks `"md"`.

- [ ] **Step 3: Implement** — in `io.ts`:

```typescript
server.registerTool(
  "rubien_import",
  {
    title: "Import from BibTeX/RIS/markdown or a folder",
    description:
      "Import references from a file (BibTeX .bib / RIS .ris / markdown .md — Obsidian Web Clipper frontmatter is mapped, plain notes import too) or a folder (Zotero export, or a folder of .md files). Folder imports stamp a single-/multi-select property value on every imported reference via property + value (default: Tags = folder basename). A folder containing both .bib and .md needs format to disambiguate.",
    inputSchema: {
      file: z
        .string()
        .describe(
          "Absolute path on the host. Stdin piping ('-') is not supported through the MCP wrapper; if you need it, invoke rubien-cli directly.",
        ),
      format: z
        .enum(["bib", "ris", "md"])
        .optional()
        .describe(
          "Override the format inferred from the file extension; also disambiguates folders containing both .bib and .md.",
        ),
      property: z
        .string()
        .optional()
        .describe("(Folder imports) Property name to stamp on imported refs"),
      value: z
        .string()
        .optional()
        .describe("(Folder imports) Value for --property on imported refs"),
    },
    annotations: { destructiveHint: true },
  },
  // handler unchanged
```

Version bump — all three places must agree:

```bash
cd mcp-server && npm version patch --no-git-tag-version
grep -n 'version' package.json src/server.ts
```

Then set `src/server.ts` line 14's `version:` to the same new value
(`SERVER_INFO` is hard-coded and does NOT read package.json).

- [ ] **Step 4: Run tests** — `cd mcp-server && npm test 2>&1 | tail -5` → all PASS.

- [ ] **Step 5: Commit + phase gate**

```bash
git add mcp-server
git commit -m "feat(mcp): rubien_import accepts md format; folder stamping; version bump"
```

**Phase 4 gate:** codex-rescue + `/simplify` on the phase diff, then the feature is complete.

---

## Completion checklist (run after Task 13)

- [ ] `swift build && swift build --product rubien-cli` → clean.
- [ ] `swift test --filter RubienCoreTests && swift test --filter RubienSyncTests && swift test --filter RubienCLITests` → green, each with a non-zero executed-test count.
- [ ] `cd mcp-server && npm test` → green.
- [ ] Hard-coded type-list sweep is an ASSERTION, not a discovery step: `grep -rn 'Magazine Article\|Preprint\|Blog Post' Docs/ | grep -v superpowers` → no hits; `grep -rln 'Journal Article' Docs/ Sources/ | xargs grep -l 'Markdown' ` → every file listing types includes Markdown. Any unexplained match = unfinished Task 10.
- [ ] `grep -n 'version' mcp-server/package.json mcp-server/src/server.ts` → same version string.
- [ ] Manual app pass from Task 12 Step 5 done on a real library copy.
