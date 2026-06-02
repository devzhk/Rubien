import XCTest
import GRDB
@testable import RubienCore

/// Covers the routing layer that makes the seeded "Tags" PropertyDefinition
/// (defaultFieldKey == "tags") behave like a regular multiSelect property
/// from the CLI / MCP, while writes flow through the Tag + ReferenceTag
/// tables underneath. This is the contract the CLI/MCP unification depends
/// on; sync correctness (tombstones for cascaded pivots) is part of it.
final class TagsPropertyRoutingTests: XCTestCase {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private func tagsProp(_ db: AppDatabase) throws -> PropertyDefinition {
        let defs = try db.fetchAllPropertyDefinitions()
        return defs.first { $0.defaultFieldKey == PropertyDefinition.tagsFieldKey }!
    }

    private func makeRef(_ db: AppDatabase, title: String = "ref") throws -> Int64 {
        var ref = Reference(title: title)
        try db.saveReference(&ref)
        return ref.id!
    }

    private func makeTag(_ db: AppDatabase, name: String, color: String = "#000000") throws -> Int64 {
        var tag = Tag(name: name, color: color)
        try db.saveTag(&tag)
        return tag.id!
    }

    // MARK: - setPropertyValue routing

    func testSetPropertyValueOnTagsRoutesToReferenceTagNotPropertyValue() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let tagId = try makeTag(db, name: "ml")
        let prop = try tagsProp(db)

        // Pass JSON-encoded array of stringified tag ids — same shape the
        // CLI's --set produces for multiSelect.
        let encoded = PropertyValue.encodeMultiSelect([String(tagId)])
        try db.setPropertyValue(referenceId: refId, propertyId: prop.id!, value: encoded)

        // ReferenceTag pivot must have one row; propertyValue must have zero.
        try db.dbWriter.read { dbConn in
            let pivots = try Int.fetchOne(
                dbConn,
                sql: "SELECT COUNT(*) FROM referenceTag WHERE referenceId = ? AND tagId = ?",
                arguments: [refId, tagId]
            ) ?? 0
            XCTAssertEqual(pivots, 1, "Tags --set must write a ReferenceTag pivot row")
            let pvRows = try Int.fetchOne(
                dbConn,
                sql: "SELECT COUNT(*) FROM propertyValue WHERE referenceId = ? AND propertyId = ?",
                arguments: [refId, prop.id!]
            ) ?? 0
            XCTAssertEqual(pvRows, 0, "Tags --set must NOT write a propertyValue row (would dangle in sync)")
        }
    }

    func testSetPropertyValueOnTagsAcceptsCommaSeparatedIds() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let t1 = try makeTag(db, name: "a")
        let t2 = try makeTag(db, name: "b")
        let prop = try tagsProp(db)

        try db.setPropertyValue(referenceId: refId, propertyId: prop.id!, value: "\(t1),\(t2)")

        let tags = try db.fetchTags(forReference: refId)
        XCTAssertEqual(Set(tags.compactMap(\.id)), [t1, t2])
    }

    func testSetPropertyValueOnTagsWithNilClearsAllPivots() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let t1 = try makeTag(db, name: "a")
        let t2 = try makeTag(db, name: "b")
        try db.setTags(forReference: refId, tagIds: [t1, t2])
        XCTAssertEqual(try db.fetchTags(forReference: refId).count, 2)

        let prop = try tagsProp(db)
        try db.setPropertyValue(referenceId: refId, propertyId: prop.id!, value: nil)

        XCTAssertEqual(try db.fetchTags(forReference: refId).count, 0)
    }

    // MARK: - fetchPropertyValues projection

    func testFetchPropertyValuesProjectsTagsAsMultiSelect() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let t1 = try makeTag(db, name: "a")
        let t2 = try makeTag(db, name: "b")
        try db.setTags(forReference: refId, tagIds: [t1, t2])

        let prop = try tagsProp(db)
        let values = try db.fetchPropertyValues(forReference: refId)
        guard let row = values.first(where: { $0.propertyId == prop.id }) else {
            XCTFail("fetchPropertyValues must include a synthetic Tags row when the reference has tags")
            return
        }
        let decoded = Set(PropertyValue.decodeMultiSelect(row.value ?? ""))
        XCTAssertEqual(decoded, [String(t1), String(t2)])
    }

    func testFetchPropertyValuesOmitsTagsWhenReferenceHasNone() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let prop = try tagsProp(db)

        let values = try db.fetchPropertyValues(forReference: refId)
        XCTAssertFalse(values.contains { $0.propertyId == prop.id },
                       "no Tags row should appear when the reference has zero tags")
    }

    // MARK: - addPropertyValue / removePropertyValue (Tags)

    func testAddPropertyValueOnTagsIsIdempotent() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let tagId = try makeTag(db, name: "x")
        let prop = try tagsProp(db)

        try db.addPropertyValue(referenceId: refId, propertyId: prop.id!, values: [String(tagId)])
        try db.addPropertyValue(referenceId: refId, propertyId: prop.id!, values: [String(tagId)])

        let tags = try db.fetchTags(forReference: refId)
        XCTAssertEqual(tags.count, 1, "re-adding an already-present tag must not create a second pivot row")
    }

    func testRemovePropertyValueOnTagsIsIdempotent() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let tagId = try makeTag(db, name: "x")
        let prop = try tagsProp(db)
        try db.setTags(forReference: refId, tagIds: [tagId])

        try db.removePropertyValue(referenceId: refId, propertyId: prop.id!, values: [String(tagId)])
        try db.removePropertyValue(referenceId: refId, propertyId: prop.id!, values: [String(tagId)])

        XCTAssertEqual(try db.fetchTags(forReference: refId).count, 0)
    }

    func testAddPropertyValueOnTagsRejectsUnknownId() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let prop = try tagsProp(db)
        XCTAssertThrowsError(
            try db.addPropertyValue(referenceId: refId, propertyId: prop.id!, values: ["999999"])
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionNotFound)
        }
    }

    // MARK: - addPropertyValue / removePropertyValue (custom multiSelect)

    func testAddRemovePropertyValueOnCustomMultiSelectIsIdempotent() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        var def = PropertyDefinition(
            name: "modality",
            type: .multiSelect,
            options: [
                SelectOption(value: "ml", color: "#000000"),
                SelectOption(value: "nlp", color: "#111111"),
                SelectOption(value: "vision", color: "#222222"),
            ],
            sortOrder: 999,
            isDefault: false,
            isVisible: true
        )
        try db.savePropertyDefinition(&def)
        let propId = def.id!

        try db.addPropertyValue(referenceId: refId, propertyId: propId, values: ["ml", "nlp"])
        try db.addPropertyValue(referenceId: refId, propertyId: propId, values: ["ml"]) // idempotent
        let after1 = try db.fetchPropertyValues(forReference: refId)
            .first { $0.propertyId == propId }?
            .value
        XCTAssertEqual(Set(PropertyValue.decodeMultiSelect(after1 ?? "")), ["ml", "nlp"])

        try db.removePropertyValue(referenceId: refId, propertyId: propId, values: ["nlp"])
        try db.removePropertyValue(referenceId: refId, propertyId: propId, values: ["nlp"]) // idempotent
        let after2 = try db.fetchPropertyValues(forReference: refId)
            .first { $0.propertyId == propId }?
            .value
        XCTAssertEqual(Set(PropertyValue.decodeMultiSelect(after2 ?? "")), ["ml"])
    }

    // MARK: - addPropertyOption (Tags creates Tag row, returns id)

    func testAddPropertyOptionOnTagsCreatesTagRowAndReturnsId() throws {
        let db = try makeDB()
        let prop = try tagsProp(db)

        let returnedValue = try db.addPropertyOption(propertyId: prop.id!, value: "robotics", color: "#FF0066")

        // Returned value must be the new tag's id (stringified) — the canonical
        // option identity for Tags-routed options.
        guard let newId = Int64(returnedValue),
              let tag = try db.dbWriter.read({ try Tag.fetchOne($0, id: newId) }) else {
            XCTFail("addPropertyOption on Tags must return the new tag id; got: \(returnedValue)")
            return
        }
        XCTAssertEqual(tag.name, "robotics")
        XCTAssertEqual(tag.color, "#FF0066")
    }

    func testAddPropertyOptionOnTagsRejectsDuplicateName() throws {
        let db = try makeDB()
        let prop = try tagsProp(db)
        _ = try db.addPropertyOption(propertyId: prop.id!, value: "ml", color: nil)
        XCTAssertThrowsError(
            try db.addPropertyOption(propertyId: prop.id!, value: "ml", color: nil)
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .duplicateValue("ml"))
        }
    }

    // MARK: - rename / delete by tag id

    func testRenamePropertyOptionOnTagsRenamesTagWithoutTouchingPivots() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let tagId = try makeTag(db, name: "ml")
        try db.setTags(forReference: refId, tagIds: [tagId])
        let prop = try tagsProp(db)

        try db.renamePropertyOption(propertyId: prop.id!, from: String(tagId), to: "machine-learning")

        let tags = try db.fetchTags(forReference: refId)
        XCTAssertEqual(tags.count, 1, "rename must not affect pivots — tag id is the identity")
        XCTAssertEqual(tags.first?.id, tagId)
        XCTAssertEqual(tags.first?.name, "machine-learning")
    }

    /// Regression: renaming a Tag to its current name (idempotent rename) must
    /// be a no-op, not throw `.duplicateValue`. The duplicate check has to
    /// exclude the row being renamed because `from` is an id and `to` is a
    /// name (different domains, so the function-level `from != to` early-out
    /// can't catch this case).
    func testRenamePropertyOptionOnTagsToCurrentNameIsNoOp() throws {
        let db = try makeDB()
        let tagId = try makeTag(db, name: "ml")
        let prop = try tagsProp(db)

        XCTAssertNoThrow(
            try db.renamePropertyOption(propertyId: prop.id!, from: String(tagId), to: "ml")
        )
        // Tag still exists with original name.
        let tag = try db.dbWriter.read { try Tag.fetchOne($0, id: tagId) }
        XCTAssertEqual(tag?.name, "ml")
    }

    /// Regression: passing the deleted option's own value as `replaceWith`
    /// is meaningless and would silently leave the DB inconsistent — Tags
    /// would re-tag everything to the about-to-be-deleted tag, and custom
    /// multiSelect would rewrite arrays back to a value about to be removed
    /// from optionsJSON. Reject up front with `replacementNotFound`.
    func testDeletePropertyOptionRejectsSelfReplacement() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let tagId = try makeTag(db, name: "x")
        try db.setTags(forReference: refId, tagIds: [tagId])
        let prop = try tagsProp(db)

        XCTAssertThrowsError(
            try db.deletePropertyOption(propertyId: prop.id!, value: String(tagId), replaceWith: String(tagId))
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .replacementNotFound(String(tagId)))
        }
        // Tag and pivot must still exist.
        XCTAssertNotNil(try db.dbWriter.read { try Tag.fetchOne($0, id: tagId) })
        XCTAssertEqual(try db.fetchTags(forReference: refId).count, 1)
    }

    /// Regression: setPropertyValue's Tags routing must reject unknown tag
    /// ids cleanly (matching addPropertyValue's contract) instead of
    /// surfacing a lower-level FK constraint failure.
    func testSetPropertyValueOnTagsRejectsUnknownIdCleanly() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let prop = try tagsProp(db)

        XCTAssertThrowsError(
            try db.setPropertyValue(referenceId: refId, propertyId: prop.id!, value: "999999")
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionNotFound)
        }
    }

    /// `--delete-option` on Tags follows the same in-use protection that
    /// custom singleSelect deletion does — caller must explicitly opt in
    /// via `replaceWith` (or know the tag has no attachments). Surfacing
    /// `optionInUse` is preferable to silently orphaning user data.
    func testDeletePropertyOptionOnTagsErrorsWhenInUseWithoutReplacement() throws {
        let db = try makeDB()
        let refId = try makeRef(db)
        let tagId = try makeTag(db, name: "in-use")
        try db.setTags(forReference: refId, tagIds: [tagId])

        let prop = try tagsProp(db)
        XCTAssertThrowsError(
            try db.deletePropertyOption(propertyId: prop.id!, value: String(tagId))
        ) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionInUse(count: 1))
        }
        // Tag must still exist + still attached.
        XCTAssertNotNil(try db.dbWriter.read { try Tag.fetchOne($0, id: tagId) })
        XCTAssertEqual(try db.fetchTags(forReference: refId).count, 1)
    }

    func testDeletePropertyOptionOnTagsRemovesUnattachedTag() throws {
        let db = try makeDB()
        let tagId = try makeTag(db, name: "unattached")
        let prop = try tagsProp(db)
        try db.deletePropertyOption(propertyId: prop.id!, value: String(tagId))
        XCTAssertNil(try db.dbWriter.read { try Tag.fetchOne($0, id: tagId) })
    }

    /// Sync invariant: deleting a Tag that has attached references must
    /// produce tombstones for both `CDTag` AND every cascaded `CDReferenceTag`
    /// pivot. SQLite fires AFTER DELETE triggers on FK-cascaded rows by
    /// default (recursive_triggers = ON), but the project's sync correctness
    /// depends on that, so cover it explicitly. Without these tombstones,
    /// other devices would see "deleted" tags resurrect through the still-
    /// alive pivot records on iCloud.
    ///
    /// We exercise the trigger via `deleteTag(id:)` directly because
    /// `deletePropertyOption` requires a replaceWith for in-use tags
    /// (intentional safety) — the trigger code path is the same either way.
    func testDeleteTagCascadesTombstonesForBothEntities() throws {
        let db = try makeDB()
        let refA = try makeRef(db, title: "A")
        let refB = try makeRef(db, title: "B")
        let tagId = try makeTag(db, name: "soon-to-die")
        try db.setTags(forReference: refA, tagIds: [tagId])
        try db.setTags(forReference: refB, tagIds: [tagId])

        // Clear pre-existing tombstones from earlier mutations so the
        // assertion sees only the cascade-emitted ones.
        try db.dbWriter.write { dbConn in
            try dbConn.execute(sql: "DELETE FROM tombstone")
        }

        try db.deleteTag(id: tagId)

        let entries = try db.dbWriter.read { dbConn in
            try Row.fetchAll(dbConn, sql: "SELECT entityType, entityId FROM tombstone")
        }
        let pairs: [(String, String)] = entries.map { ($0["entityType"] ?? "", $0["entityId"] ?? "") }

        XCTAssertTrue(
            pairs.contains(where: { $0.0 == "tag" && $0.1 == String(tagId) }),
            "expected a CDTag tombstone for the deleted tag; got \(pairs)"
        )
        XCTAssertTrue(
            pairs.contains(where: { $0.0 == "referenceTag" && $0.1 == "\(refA)/\(tagId)" }),
            "expected a CDReferenceTag tombstone for refA cascade; got \(pairs)"
        )
        XCTAssertTrue(
            pairs.contains(where: { $0.0 == "referenceTag" && $0.1 == "\(refB)/\(tagId)" }),
            "expected a CDReferenceTag tombstone for refB cascade; got \(pairs)"
        )
    }

    func testDeletePropertyOptionOnTagsWithReplacementMigratesPivots() throws {
        let db = try makeDB()
        let refA = try makeRef(db, title: "A")
        let refB = try makeRef(db, title: "B")
        let oldTag = try makeTag(db, name: "old")
        let newTag = try makeTag(db, name: "new")
        try db.setTags(forReference: refA, tagIds: [oldTag])
        try db.setTags(forReference: refB, tagIds: [oldTag, newTag])

        let prop = try tagsProp(db)
        try db.deletePropertyOption(
            propertyId: prop.id!,
            value: String(oldTag),
            replaceWith: String(newTag)
        )

        XCTAssertEqual(try db.fetchTags(forReference: refA).map(\.id), [newTag])
        XCTAssertEqual(Set(try db.fetchTags(forReference: refB).compactMap(\.id)), [newTag])
    }

    // MARK: - probeDeletePropertyOption on Tags (TagPickerPopover gate contract)

    func testProbeDeleteUnusedTagDeletesItAndReturnsNil() throws {
        let db = try makeDB()
        let prop = try tagsProp(db)
        let tagId = try makeTag(db, name: "orphan", color: "#FF0000")

        let count = db.probeDeletePropertyOption(propertyId: prop.id!, value: String(tagId))

        XCTAssertNil(count)                                              // unused → deleted outright, no confirm
        XCTAssertNil(try db.fetchAllTags().first { $0.id == tagId })   // tag is gone
    }

    func testProbeDeleteInUseTagReturnsCountWithoutDeleting() throws {
        let db = try makeDB()
        let prop = try tagsProp(db)
        let refId = try makeRef(db, title: "Paper")
        let tagId = try makeTag(db, name: "acceleration", color: "#FF9500")
        try db.setTags(forReference: refId, tagIds: [tagId])

        let count = db.probeDeletePropertyOption(propertyId: prop.id!, value: String(tagId))

        XCTAssertEqual(count, 1)                                         // in use → confirm, nothing deleted
        XCTAssertNotNil(try db.fetchAllTags().first { $0.id == tagId }) // tag still present
    }

    func testProbeDeleteTagUsedByMultipleReferencesReturnsFullCountAndKeepsPivots() throws {
        let db = try makeDB()
        let prop = try tagsProp(db)
        let ref1 = try makeRef(db, title: "Paper 1")
        let ref2 = try makeRef(db, title: "Paper 2")
        let tagId = try makeTag(db, name: "shared", color: "#5856D6")
        try db.setTags(forReference: ref1, tagIds: [tagId])
        try db.setTags(forReference: ref2, tagIds: [tagId])

        let count = db.probeDeletePropertyOption(propertyId: prop.id!, value: String(tagId))

        XCTAssertEqual(count, 2)                                         // full in-use count drives the "N references" copy
        XCTAssertNotNil(try db.fetchAllTags().first { $0.id == tagId }) // tag survives the blocked probe
        // The in-use probe is non-destructive: both pivots must remain.
        let pivots = try db.dbWriter.read { dbConn in
            try Int.fetchOne(
                dbConn,
                sql: "SELECT COUNT(*) FROM referenceTag WHERE tagId = ?",
                arguments: [tagId]
            ) ?? 0
        }
        XCTAssertEqual(pivots, 2, "in-use probe must not delete referenceTag pivots")
    }
}
