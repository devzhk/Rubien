import XCTest
import GRDB
@testable import RubienCore

/// Phase 2: covers the option mutation methods that back the user-extensible
/// Status feature. Same machinery is used for any custom singleSelect property
/// — Status is just the first built-in that opts in.
final class StatusOptionMutationTests: XCTestCase {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// Resolves the seeded Status PropertyDefinition for assertions.
    private func statusDef(_ db: AppDatabase) throws -> PropertyDefinition {
        let defs = try db.fetchAllPropertyDefinitions()
        return defs.first { $0.defaultFieldKey == "readingStatus" }!
    }

    // MARK: - renamePropertyOption

    /// Renaming a Status option updates BOTH the PropertyDefinition's
    /// optionsJSON AND every reference's `readingStatus` column that pointed
    /// to the old value. Without the bulk-update half, the rename would
    /// silently orphan existing rows.
    func testRenameStatusOptionUpdatesReferenceRows() throws {
        let db = try makeDB()
        // Insert a couple of references with the status we're about to rename.
        try db.dbWriter.write { writer in
            try writer.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus)
                VALUES (1, 'a', ?, ?, 'Skimmed'),
                       (2, 'b', ?, ?, 'Skimmed'),
                       (3, 'c', ?, ?, 'Read')
            """, arguments: [
                Date(), Date(), Date(), Date(), Date(), Date()
            ])
        }

        let prop = try statusDef(db)
        try db.renamePropertyOption(propertyId: prop.id!, from: "Skimmed", to: "Glanced")

        try db.dbWriter.read { reader in
            let renamedCount = try Int.fetchOne(
                reader,
                sql: "SELECT COUNT(*) FROM reference WHERE readingStatus = 'Glanced'"
            ) ?? -1
            XCTAssertEqual(renamedCount, 2, "both references previously 'Skimmed' must now show 'Glanced'")
            let strayCount = try Int.fetchOne(
                reader,
                sql: "SELECT COUNT(*) FROM reference WHERE readingStatus = 'Skimmed'"
            ) ?? -1
            XCTAssertEqual(strayCount, 0, "no references must still point at the old value")
            let untouched = try Int.fetchOne(
                reader,
                sql: "SELECT COUNT(*) FROM reference WHERE readingStatus = 'Read'"
            ) ?? -1
            XCTAssertEqual(untouched, 1, "unrelated statuses must not be modified")
        }

        let updated = try statusDef(db)
        XCTAssertEqual(
            updated.options.map(\.value).sorted(),
            ["Glanced", "Read", "Unread"],
            "optionsJSON must reflect the rename, with the original color preserved on the renamed option"
        )
        let renamedOption = updated.options.first { $0.value == "Glanced" }!
        XCTAssertEqual(renamedOption.color, "#FF9500", "Skimmed's orange color must follow the option through the rename")
    }

    /// Adding a custom Status option then renaming it works identically to
    /// renaming a built-in — there's no special path for built-ins.
    func testRenameAddedCustomStatusOption() throws {
        let db = try makeDB()
        var prop = try statusDef(db)
        _ = prop.addOptionIfMissing("To Skim")
        try db.savePropertyDefinition(&prop)

        try db.dbWriter.write { writer in
            try writer.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus)
                VALUES (1, 'a', ?, ?, 'To Skim')
            """, arguments: [Date(), Date()])
        }

        try db.renamePropertyOption(propertyId: prop.id!, from: "To Skim", to: "Queued")

        try db.dbWriter.read { reader in
            let value = try String.fetchOne(reader, sql: "SELECT readingStatus FROM reference WHERE id = 1")
            XCTAssertEqual(value, "Queued")
        }
    }

    /// Renaming with `from == to` is a no-op; nothing is mutated.
    func testRenameWithIdenticalSourceAndTargetIsNoOp() throws {
        let db = try makeDB()
        let prop = try statusDef(db)
        let before = prop.options
        try db.renamePropertyOption(propertyId: prop.id!, from: "Skimmed", to: "Skimmed")
        let after = try statusDef(db).options
        XCTAssertEqual(before, after, "no-op rename must leave optionsJSON exactly as it was")
    }

    /// Trying to rename a value that isn't in the option list throws.
    func testRenameNonExistentOptionThrowsOptionNotFound() throws {
        let db = try makeDB()
        let prop = try statusDef(db)
        XCTAssertThrowsError(
            try db.renamePropertyOption(propertyId: prop.id!, from: "NonExistent", to: "Whatever")
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionNotFound)
        }
    }

    /// Trying to operate on a property id that doesn't exist throws.
    func testRenameOnNonExistentPropertyThrowsPropertyNotFound() throws {
        let db = try makeDB()
        XCTAssertThrowsError(
            try db.renamePropertyOption(propertyId: 999_999, from: "Reading", to: "Whatever")
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .propertyNotFound)
        }
    }

    // MARK: - deletePropertyOption

    /// Deleting an unused option succeeds and just trims the options list.
    func testDeleteUnusedOptionSucceedsWithoutReplacement() throws {
        let db = try makeDB()
        var prop = try statusDef(db)
        _ = prop.addOptionIfMissing("Backlog")
        try db.savePropertyDefinition(&prop)

        try db.deletePropertyOption(propertyId: prop.id!, value: "Backlog", replaceWith: nil)

        let after = try statusDef(db)
        XCTAssertFalse(after.options.contains { $0.value == "Backlog" })
    }

    /// Deleting an option that's currently in use without supplying
    /// `replaceWith` throws `.optionInUse(count:)` so the caller can prompt.
    func testDeleteInUseOptionWithoutReplacementThrowsOptionInUse() throws {
        let db = try makeDB()
        let prop = try statusDef(db)
        try db.dbWriter.write { writer in
            try writer.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus)
                VALUES (1, 'a', ?, ?, 'Skimmed'),
                       (2, 'b', ?, ?, 'Skimmed')
            """, arguments: [Date(), Date(), Date(), Date()])
        }
        XCTAssertThrowsError(
            try db.deletePropertyOption(propertyId: prop.id!, value: "Skimmed", replaceWith: nil)
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionInUse(count: 2))
        }
        // The option must still be present — the throw must not have partially
        // applied the delete.
        let after = try statusDef(db)
        XCTAssertTrue(after.options.contains { $0.value == "Skimmed" })
    }

    /// Deleting an in-use option WITH a replacement reassigns the affected
    /// reference rows AND removes the option from the list.
    func testDeleteInUseOptionWithReplacementMigratesRows() throws {
        let db = try makeDB()
        let prop = try statusDef(db)
        try db.dbWriter.write { writer in
            try writer.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus)
                VALUES (1, 'a', ?, ?, 'Skimmed'),
                       (2, 'b', ?, ?, 'Skimmed'),
                       (3, 'c', ?, ?, 'Read')
            """, arguments: [Date(), Date(), Date(), Date(), Date(), Date()])
        }
        try db.deletePropertyOption(
            propertyId: prop.id!,
            value: "Skimmed",
            replaceWith: "Read"
        )
        try db.dbWriter.read { reader in
            let migrated = try Int.fetchOne(
                reader,
                sql: "SELECT COUNT(*) FROM reference WHERE readingStatus = 'Read'"
            ) ?? -1
            XCTAssertEqual(migrated, 3, "all 'Skimmed' refs become 'Read' + the original 'Read' ref")
            let stray = try Int.fetchOne(
                reader,
                sql: "SELECT COUNT(*) FROM reference WHERE readingStatus = 'Skimmed'"
            ) ?? -1
            XCTAssertEqual(stray, 0)
        }
        let after = try statusDef(db)
        XCTAssertFalse(after.options.contains { $0.value == "Skimmed" })
    }

    /// Renaming an option to a value that already exists on the same property
    /// would collapse two distinct options into one — surface .duplicateValue.
    func testRenameToExistingValueThrowsDuplicateValue() throws {
        let db = try makeDB()
        let prop = try statusDef(db)
        XCTAssertThrowsError(
            try db.renamePropertyOption(propertyId: prop.id!, from: "Skimmed", to: "Read")
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .duplicateValue("Read"))
        }
        // Both Skimmed and Read must still be present and distinct.
        let after = try statusDef(db)
        XCTAssertTrue(after.options.contains { $0.value == "Skimmed" })
        XCTAssertTrue(after.options.contains { $0.value == "Read" })
    }

    /// Custom multiSelect option rename rewrites the JSON arrays in every
    /// affected propertyValue row so stored selections stay valid. Custom
    /// multiSelect deletion follows the same in-use-protection contract as
    /// singleSelect: throws `optionInUse` unless `replaceWith` is supplied.
    /// (Tags are exercised separately in `TagsPropertyRoutingTests`.)
    func testRenameAndDeleteOnCustomMultiSelectMutateInUseRows() throws {
        let db = try makeDB()
        var custom = PropertyDefinition(
            name: "Themes",
            type: .multiSelect,
            options: [
                SelectOption(value: "ML", color: "#007AFF"),
                SelectOption(value: "Systems", color: "#34C759"),
            ],
            sortOrder: 99,
            isDefault: false,
            isVisible: true
        )
        try db.savePropertyDefinition(&custom)

        // Seed two references so we can assert the bulk JSON rewrite.
        var refA = Reference(title: "A")
        var refB = Reference(title: "B")
        try db.saveReference(&refA)
        try db.saveReference(&refB)
        try db.setPropertyValue(
            referenceId: refA.id!,
            propertyId: custom.id!,
            value: PropertyValue.encodeMultiSelect(["ML"])
        )
        try db.setPropertyValue(
            referenceId: refB.id!,
            propertyId: custom.id!,
            value: PropertyValue.encodeMultiSelect(["ML", "Systems"])
        )

        // Rename "ML" → "MachineLearning". Both rows must rewrite their
        // arrays in place; "Systems" stays put.
        try db.renamePropertyOption(propertyId: custom.id!, from: "ML", to: "MachineLearning")

        let updated = try db.fetchAllPropertyDefinitions().first { $0.id == custom.id }!
        XCTAssertEqual(Set(updated.options.map(\.value)), ["MachineLearning", "Systems"])
        let valueA = try db.fetchPropertyValues(forReference: refA.id!)
            .first { $0.propertyId == custom.id }?.value
        XCTAssertEqual(PropertyValue.decodeMultiSelect(valueA ?? ""), ["MachineLearning"])
        let valueB = try db.fetchPropertyValues(forReference: refB.id!)
            .first { $0.propertyId == custom.id }?.value
        XCTAssertEqual(Set(PropertyValue.decodeMultiSelect(valueB ?? "")), ["MachineLearning", "Systems"])

        // Delete with no replacement: refuse, surface in-use count for the
        // 2 references that still hold the value.
        XCTAssertThrowsError(
            try db.deletePropertyOption(propertyId: custom.id!, value: "MachineLearning", replaceWith: nil)
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionInUse(count: 2))
        }

        // Delete with replacement: rewrite "MachineLearning" → "Systems"
        // (deduping the duplicate on refB), then drop the option.
        try db.deletePropertyOption(propertyId: custom.id!, value: "MachineLearning", replaceWith: "Systems")
        let final = try db.fetchAllPropertyDefinitions().first { $0.id == custom.id }!
        XCTAssertEqual(final.options.map(\.value), ["Systems"])
        let finalA = try db.fetchPropertyValues(forReference: refA.id!)
            .first { $0.propertyId == custom.id }?.value
        XCTAssertEqual(PropertyValue.decodeMultiSelect(finalA ?? ""), ["Systems"])
        let finalB = try db.fetchPropertyValues(forReference: refB.id!)
            .first { $0.propertyId == custom.id }?.value
        XCTAssertEqual(PropertyValue.decodeMultiSelect(finalB ?? ""), ["Systems"])
    }

    /// Supplying a replacement that isn't itself an existing option is a
    /// caller bug; surface it instead of writing a dangling value.
    func testDeleteWithUnknownReplacementThrowsReplacementNotFound() throws {
        let db = try makeDB()
        let prop = try statusDef(db)
        try db.dbWriter.write { writer in
            try writer.execute(sql: """
                INSERT INTO reference(id, title, dateAdded, dateModified, readingStatus)
                VALUES (1, 'a', ?, ?, 'Skimmed')
            """, arguments: [Date(), Date()])
        }
        XCTAssertThrowsError(
            try db.deletePropertyOption(
                propertyId: prop.id!,
                value: "Skimmed",
                replaceWith: "MadeUpStatus"
            )
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .replacementNotFound("MadeUpStatus"))
        }
    }

    // MARK: - deletePropertyOption(clearInUse:)

    private func customSelect(
        _ db: AppDatabase,
        name: String,
        type: PropertyType,
        options: [SelectOption]
    ) throws -> PropertyDefinition {
        var prop = PropertyDefinition(
            name: name,
            type: type,
            options: options,
            sortOrder: 99,
            isDefault: false,
            isVisible: true
        )
        try db.savePropertyDefinition(&prop)
        return prop
    }

    /// Clearing an in-use singleSelect option deletes the affected
    /// `propertyValue` rows (the reference loses its value entirely) rather
    /// than reassigning them, and drops the option from the definition.
    func testClearOnCustomSingleSelectDeletesPropertyValueRows() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Method", type: .singleSelect, options: [
            SelectOption(value: "Empirical", color: "#007AFF"),
            SelectOption(value: "Theory", color: "#34C759"),
        ])
        var refA = Reference(title: "A"); try db.saveReference(&refA)
        var refB = Reference(title: "B"); try db.saveReference(&refB)
        try db.setPropertyValue(referenceId: refA.id!, propertyId: custom.id!, value: "Empirical")
        try db.setPropertyValue(referenceId: refB.id!, propertyId: custom.id!, value: "Empirical")

        try db.deletePropertyOption(propertyId: custom.id!, value: "Empirical", clearInUse: true)

        let updated = try db.fetchAllPropertyDefinitions().first { $0.id == custom.id }!
        XCTAssertEqual(updated.options.map(\.value), ["Theory"])
        XCTAssertNil(try db.fetchPropertyValues(forReference: refA.id!).first { $0.propertyId == custom.id })
        XCTAssertNil(try db.fetchPropertyValues(forReference: refB.id!).first { $0.propertyId == custom.id })
    }

    /// Clearing a multiSelect option drops only that option from each
    /// reference's array; other selections survive.
    func testClearOnCustomMultiSelectLeavesOtherSelections() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Themes", type: .multiSelect, options: [
            SelectOption(value: "ML", color: "#007AFF"),
            SelectOption(value: "Systems", color: "#34C759"),
        ])
        var ref = Reference(title: "A"); try db.saveReference(&ref)
        try db.setPropertyValue(
            referenceId: ref.id!,
            propertyId: custom.id!,
            value: PropertyValue.encodeMultiSelect(["ML", "Systems"])
        )

        try db.deletePropertyOption(propertyId: custom.id!, value: "ML", clearInUse: true)

        let updated = try db.fetchAllPropertyDefinitions().first { $0.id == custom.id }!
        XCTAssertEqual(updated.options.map(\.value), ["Systems"])
        let value = try db.fetchPropertyValues(forReference: ref.id!).first { $0.propertyId == custom.id }?.value
        XCTAssertEqual(PropertyValue.decodeMultiSelect(value ?? ""), ["Systems"])
    }

    /// Clearing the last remaining multiSelect option on a reference empties
    /// the array, which must delete the row (never persist a `"[]"`/`""` row)
    /// to keep the "no row == empty" invariant `setPropertyValue` relies on.
    func testClearOnCustomMultiSelectEmptyingArrayDeletesRow() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Themes", type: .multiSelect, options: [
            SelectOption(value: "ML", color: "#007AFF"),
        ])
        var ref = Reference(title: "A"); try db.saveReference(&ref)
        try db.setPropertyValue(
            referenceId: ref.id!,
            propertyId: custom.id!,
            value: PropertyValue.encodeMultiSelect(["ML"])
        )

        try db.deletePropertyOption(propertyId: custom.id!, value: "ML", clearInUse: true)

        XCTAssertNil(
            try db.fetchPropertyValues(forReference: ref.id!).first { $0.propertyId == custom.id },
            "emptied multiSelect must delete the row, not store an empty array"
        )
    }

    /// `clearInUse` on an option no reference uses behaves like a plain delete:
    /// the option is removed with no error and no row churn.
    func testClearOnUnusedOptionJustRemovesIt() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Method", type: .singleSelect, options: [
            SelectOption(value: "Empirical", color: "#007AFF"),
            SelectOption(value: "Theory", color: "#34C759"),
        ])
        try db.deletePropertyOption(propertyId: custom.id!, value: "Empirical", clearInUse: true)
        let updated = try db.fetchAllPropertyDefinitions().first { $0.id == custom.id }!
        XCTAssertEqual(updated.options.map(\.value), ["Theory"])
    }

    /// `replaceWith` and `clearInUse` are conflicting in-use dispositions;
    /// supplying both is a caller bug and throws a dedicated error (not the
    /// misleading `.replacementNotFound`).
    func testClearAndReplaceWithThrowConflictingDisposition() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Method", type: .singleSelect, options: [
            SelectOption(value: "Empirical", color: "#007AFF"),
            SelectOption(value: "Theory", color: "#34C759"),
        ])
        XCTAssertThrowsError(
            try db.deletePropertyOption(
                propertyId: custom.id!,
                value: "Empirical",
                replaceWith: "Theory",
                clearInUse: true
            )
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .conflictingDisposition)
        }
    }

    /// The fixed Type property's column has no empty raw value, so clearing it
    /// to `''` would corrupt rows on decode. The data layer rejects it rather
    /// than relying on the UI/CLI gate alone.
    func testClearOnReferenceTypeIsRejected() throws {
        let db = try makeDB()
        let typeDef = try db.fetchAllPropertyDefinitions().first { $0.defaultFieldKey == "referenceType" }!
        var ref = Reference(title: "A")
        ref.referenceType = .book
        try db.saveReference(&ref)

        XCTAssertThrowsError(
            try db.deletePropertyOption(propertyId: typeDef.id!, value: ReferenceType.book.rawValue, clearInUse: true)
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .unsupportedPropertyType)
        }
        let stored = try db.dbWriter.read {
            try String.fetchOne($0, sql: "SELECT referenceType FROM reference WHERE id = ?", arguments: [ref.id!])
        }
        XCTAssertEqual(stored, ReferenceType.book.rawValue, "the Type column must be untouched")
    }

    /// Option values can contain JSON-escapable characters (e.g. embedded
    /// quotes). The multiSelect affected-row scan must find such values despite
    /// JSON escaping, or the clear would silently leave the stale value behind.
    func testClearOnMultiSelectWithQuotedOptionValueClearsRow() throws {
        let db = try makeDB()
        let quoted = "say \"hi\""
        let custom = try customSelect(db, name: "Themes", type: .multiSelect, options: [
            SelectOption(value: quoted, color: "#007AFF"),
            SelectOption(value: "Systems", color: "#34C759"),
        ])
        var ref = Reference(title: "A"); try db.saveReference(&ref)
        try db.setPropertyValue(
            referenceId: ref.id!,
            propertyId: custom.id!,
            value: PropertyValue.encodeMultiSelect([quoted, "Systems"])
        )

        try db.deletePropertyOption(propertyId: custom.id!, value: quoted, clearInUse: true)

        let value = try db.fetchPropertyValues(forReference: ref.id!).first { $0.propertyId == custom.id }?.value
        XCTAssertEqual(
            PropertyValue.decodeMultiSelect(value ?? ""),
            ["Systems"],
            "quoted option must be found and cleared despite JSON escaping"
        )
    }

    /// Clearing a custom singleSelect deletes its `propertyValue` rows, which
    /// must emit a tombstone so the deletion propagates to other devices via
    /// CloudKit (the dirty/tombstone trigger fires on the raw-SQL DELETE).
    func testClearOnCustomSingleSelectEmitsPropertyValueTombstone() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Method", type: .singleSelect, options: [
            SelectOption(value: "Empirical", color: "#007AFF"),
            SelectOption(value: "Theory", color: "#34C759"),
        ])
        var ref = Reference(title: "A"); try db.saveReference(&ref)
        try db.setPropertyValue(referenceId: ref.id!, propertyId: custom.id!, value: "Empirical")

        // Drop pre-existing tombstones so the assertion sees only the clear's.
        try db.dbWriter.write { try $0.execute(sql: "DELETE FROM tombstone") }

        try db.deletePropertyOption(propertyId: custom.id!, value: "Empirical", clearInUse: true)

        let types = try db.dbWriter.read {
            try String.fetchAll($0, sql: "SELECT entityType FROM tombstone")
        }
        XCTAssertTrue(
            types.contains("propertyValue"),
            "clearing a custom singleSelect must tombstone the deleted propertyValue row; got \(types)"
        )
    }

    /// Clearing a built-in Status option resets the `reference.readingStatus`
    /// column to empty and marks the affected reference dirty for sync.
    func testClearOnBuiltInStatusResetsColumnAndMarksReferenceDirty() throws {
        let db = try makeDB()
        var def = try statusDef(db)
        _ = def.addOptionIfMissing("Skimming")
        try db.savePropertyDefinition(&def)
        var ref = Reference(title: "A")
        ref.readingStatus = "Skimming"
        try db.saveReference(&ref)

        // Drop pre-existing sync state so we observe only the clear's effect.
        try db.dbWriter.write { try $0.execute(sql: "DELETE FROM syncState") }

        try db.deletePropertyOption(propertyId: def.id!, value: "Skimming", clearInUse: true)

        let status = try db.dbWriter.read {
            try String.fetchOne($0, sql: "SELECT readingStatus FROM reference WHERE id = ?", arguments: [ref.id!])
        }
        XCTAssertEqual(status, "", "built-in Status clear must reset the column to empty")
        let dirtyReferences = try db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM syncState WHERE entityType = 'reference' AND isDirty = 1") ?? 0
        }
        XCTAssertGreaterThan(dirtyReferences, 0, "the cleared reference must be marked dirty for sync")
    }

    // MARK: - probeDeletePropertyOption (fail-closed delete probe)

    /// The probe deletes an unused option outright and returns nil — the picker
    /// reads that as "nothing to confirm".
    func testProbeDeletePropertyOptionDeletesUnusedOptionReturningNil() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Method", type: .singleSelect, options: [
            SelectOption(value: "Empirical", color: "#007AFF"),
            SelectOption(value: "Theory", color: "#34C759"),
        ])
        let result = db.probeDeletePropertyOption(propertyId: custom.id!, value: "Empirical")
        XCTAssertNil(result, "unused option must be deleted outright (no confirmation needed)")
        let updated = try db.fetchAllPropertyDefinitions().first { $0.id == custom.id }!
        XCTAssertEqual(updated.options.map(\.value), ["Theory"], "the unused option must be gone")
    }

    /// The probe leaves an in-use option intact and returns the reference count,
    /// so the picker can confirm the destructive clear first.
    func testProbeDeletePropertyOptionReportsInUseCountWithoutDeleting() throws {
        let db = try makeDB()
        let custom = try customSelect(db, name: "Method", type: .singleSelect, options: [
            SelectOption(value: "Empirical", color: "#007AFF"),
            SelectOption(value: "Theory", color: "#34C759"),
        ])
        var refA = Reference(title: "A"); try db.saveReference(&refA)
        var refB = Reference(title: "B"); try db.saveReference(&refB)
        try db.setPropertyValue(referenceId: refA.id!, propertyId: custom.id!, value: "Empirical")
        try db.setPropertyValue(referenceId: refB.id!, propertyId: custom.id!, value: "Empirical")

        let result = db.probeDeletePropertyOption(propertyId: custom.id!, value: "Empirical")
        XCTAssertEqual(result, 2, "must report the in-use reference count")
        let updated = try db.fetchAllPropertyDefinitions().first { $0.id == custom.id }!
        XCTAssertTrue(
            updated.options.contains { $0.value == "Empirical" },
            "in-use option must NOT be deleted by the probe"
        )
    }
}
