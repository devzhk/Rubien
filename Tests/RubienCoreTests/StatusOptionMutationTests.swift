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
}
