import XCTest
import GRDB
@testable import RubienCore

/// The atomic combined property/option mutation APIs (spec §6) +
/// the all-digit name guard (§4.2): `createPropertyDefinition`,
/// `updatePropertyDefinition`, `updatePropertyOption`.
final class PropertyOptionMutationTests: XCTestCase {

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private func builtin(_ db: AppDatabase, fieldKey: String) throws -> PropertyDefinition {
        try db.fetchAllPropertyDefinitions().first { $0.defaultFieldKey == fieldKey }!
    }

    private func makeRef(_ db: AppDatabase, title: String = "ref") throws -> Int64 {
        var ref = Reference(title: title)
        _ = try db.saveReference(&ref)
        return ref.id!
    }

    // MARK: - createPropertyDefinition (all-digit guard)

    func testCreateRejectsAllDigitName() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.createPropertyDefinition(name: "12345", type: .string)) { error in
            guard case PropertyMutationError.allDigitName("12345") = error else {
                return XCTFail("expected allDigitName, got \(error)")
            }
        }
    }

    func testCreateAllowsAlphanumericName() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Modality", type: .multiSelect, options: [SelectOption(value: "ml", color: "#000000")])
        XCTAssertNotNil(prop.id)
        XCTAssertFalse(prop.isDefault)
        XCTAssertEqual(prop.type, .multiSelect)
        XCTAssertEqual(prop.options.map(\.value), ["ml"])
    }

    // MARK: - updatePropertyDefinition

    func testUpdatePropertyDefinitionRenameAndVisibleInOneCall() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Old", type: .string)
        let updated = try db.updatePropertyDefinition(id: prop.id!, name: "New", visible: false, now: t1)
        XCTAssertEqual(updated.name, "New")
        XCTAssertFalse(updated.isVisible)
        XCTAssertEqual(updated.dateModified, t1)
    }

    func testUpdatePropertyDefinitionRejectsBuiltInRename() throws {
        let db = try makeDB()
        let tags = try builtin(db, fieldKey: "tags")
        XCTAssertThrowsError(try db.updatePropertyDefinition(id: tags.id!, name: "Labels")) { error in
            guard case PropertyMutationError.builtInRenameForbidden = error else {
                return XCTFail("expected builtInRenameForbidden, got \(error)")
            }
        }
    }

    func testUpdatePropertyDefinitionAllowsVisibilityToggleOnBuiltIn() throws {
        // Toggling a built-in's visibility is fine — only its *name* is locked.
        let db = try makeDB()
        let journal = try builtin(db, fieldKey: "journal")
        let updated = try db.updatePropertyDefinition(id: journal.id!, visible: true)
        XCTAssertTrue(updated.isVisible)
    }

    func testUpdatePropertyDefinitionRejectsAllDigitName() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Old", type: .string)
        XCTAssertThrowsError(try db.updatePropertyDefinition(id: prop.id!, name: "999")) { error in
            guard case PropertyMutationError.allDigitName = error else {
                return XCTFail("expected allDigitName, got \(error)")
            }
        }
    }

    func testUpdatePropertyDefinitionRejectsEmptyRequest() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Old", type: .string)
        XCTAssertThrowsError(try db.updatePropertyDefinition(id: prop.id!)) { error in
            guard case PropertyMutationError.nothingToUpdate = error else {
                return XCTFail("expected nothingToUpdate, got \(error)")
            }
        }
    }

    func testUpdatePropertyDefinitionNoOpDoesNotStamp() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Same", type: .string, now: t1)
        // Re-set to identical values → no write, dateModified unchanged.
        let updated = try db.updatePropertyDefinition(id: prop.id!, name: "Same", visible: true, now: t2)
        XCTAssertEqual(updated.dateModified, t1)
    }

    func testUpdatePropertyDefinitionMissingIdThrows() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.updatePropertyDefinition(id: 9999, name: "x")) { error in
            guard case PropertyMutationError.propertyNotFound = error else {
                return XCTFail("expected propertyNotFound, got \(error)")
            }
        }
    }

    // MARK: - updatePropertyOption (custom select)

    func testUpdateOptionRenameBulkUpdatesReferences() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let prop = try db.createPropertyDefinition(name: "Stage", type: .singleSelect, options: [SelectOption(value: "draft", color: "#111111")])
        try db.setPropertyValue(referenceId: id, propertyId: prop.id!, value: "draft")
        try db.dbWriter.write {
            try $0.execute(
                sql: "UPDATE propertyValue SET dateModified = ? WHERE referenceId = ? AND propertyId = ?",
                arguments: [t1, id, prop.id!]
            )
        }
        try db.updatePropertyOption(propertyId: prop.id!, option: "draft", newName: "final", now: t2)
        // Option renamed in the definition AND the reference's value migrated.
        let migrated = try db.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value, dateModified FROM propertyValue WHERE referenceId = ? AND propertyId = ?",
                arguments: [id, prop.id!]
            )
        }
        XCTAssertEqual(migrated?["value"] as String?, "final")
        XCTAssertEqual(migrated?["dateModified"] as Date?, t2)
        let updatedProp = try db.fetchPropertyDefinition(id: prop.id!)!
        XCTAssertEqual(updatedProp.options.map(\.value), ["final"])
    }

    func testUpdateOptionRecolorOnly() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Stage", type: .singleSelect, options: [SelectOption(value: "draft", color: "#111111")])
        try db.updatePropertyOption(propertyId: prop.id!, option: "draft", color: "#ABCDEF")
        let updated = try db.fetchPropertyDefinition(id: prop.id!)!
        XCTAssertEqual(updated.options.first?.color, "#ABCDEF")
        XCTAssertEqual(updated.options.first?.value, "draft")
    }

    func testUpdateOptionRenameAndRecolorInOneCall() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Stage", type: .multiSelect, options: [SelectOption(value: "a", color: "#111111"), SelectOption(value: "b", color: "#222222")])
        try db.updatePropertyOption(propertyId: prop.id!, option: "a", newName: "alpha", color: "#333333")
        let updated = try db.fetchPropertyDefinition(id: prop.id!)!
        XCTAssertEqual(updated.options.map(\.value), ["alpha", "b"])
        XCTAssertEqual(updated.options.first?.color, "#333333")
    }

    func testUpdateOptionRenameBulkUpdatesMultiSelectArrays() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let prop = try db.createPropertyDefinition(name: "Modality", type: .multiSelect, options: [SelectOption(value: "ml", color: "#111111"), SelectOption(value: "nlp", color: "#222222")])
        try db.setPropertyValue(referenceId: id, propertyId: prop.id!, value: PropertyValue.encodeMultiSelect(["ml", "nlp"]))
        try db.dbWriter.write {
            try $0.execute(
                sql: "UPDATE propertyValue SET dateModified = ? WHERE referenceId = ? AND propertyId = ?",
                arguments: [t1, id, prop.id!]
            )
        }
        try db.updatePropertyOption(propertyId: prop.id!, option: "ml", newName: "machine-learning", now: t2)
        let stored = try db.dbWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value, dateModified FROM propertyValue WHERE referenceId = ? AND propertyId = ?",
                arguments: [id, prop.id!]
            )
        }
        XCTAssertEqual(PropertyValue.decodeMultiSelect(stored?["value"] as String? ?? ""), ["machine-learning", "nlp"])
        XCTAssertEqual(stored?["dateModified"] as Date?, t2)
    }

    func testUpdateOptionRejectsDuplicateRenameTarget() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Stage", type: .singleSelect, options: [SelectOption(value: "a", color: "#111111"), SelectOption(value: "b", color: "#222222")])
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: prop.id!, option: "a", newName: "b")) { error in
            XCTAssertEqual(error as? PropertyOptionError, .duplicateValue("b"))
        }
    }

    func testUpdateOptionUnknownOptionThrows() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Stage", type: .singleSelect, options: [SelectOption(value: "a", color: "#111111")])
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: prop.id!, option: "zzz", newName: "b")) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionNotFound)
        }
    }

    func testUpdateOptionRejectsInvalidColor() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Stage", type: .singleSelect, options: [SelectOption(value: "a", color: "#111111")])
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: prop.id!, option: "a", color: "red")) { error in
            guard case PropertyMutationError.invalidColor("red") = error else {
                return XCTFail("expected invalidColor, got \(error)")
            }
        }
    }

    func testUpdateOptionRejectsEmptyRequest() throws {
        let db = try makeDB()
        let prop = try db.createPropertyDefinition(name: "Stage", type: .singleSelect, options: [SelectOption(value: "a", color: "#111111")])
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: prop.id!, option: "a")) { error in
            guard case PropertyMutationError.nothingToUpdate = error else {
                return XCTFail("expected nothingToUpdate, got \(error)")
            }
        }
    }

    // MARK: - Type immutability gate

    func testUpdateOptionRefusedOnTypeIncludingRecolor() throws {
        let db = try makeDB()
        let type = try builtin(db, fieldKey: "referenceType")
        // Rename refused.
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: type.id!, option: "Book", newName: "Monograph")) { error in
            guard case PropertyMutationError.immutableBuiltInOptions = error else {
                return XCTFail("expected immutableBuiltInOptions, got \(error)")
            }
        }
        // Recolor also refused (Type options are fully immutable).
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: type.id!, option: "Book", color: "#FF0000")) { error in
            guard case PropertyMutationError.immutableBuiltInOptions = error else {
                return XCTFail("expected immutableBuiltInOptions, got \(error)")
            }
        }
    }

    func testUpdateOptionAllowedOnStatus() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let status = try builtin(db, fieldKey: "readingStatus")
        // Status routes to the `readingStatus` Reference column, not a shadow
        // propertyValue row — set it through the real cell path.
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Status": .replace(.string("Skimmed"))]))
        try db.dbWriter.write {
            try $0.execute(sql: "UPDATE reference SET dateModified = ? WHERE id = ?", arguments: [t1, id])
        }
        try db.updatePropertyOption(propertyId: status.id!, option: "Skimmed", newName: "Browsed", now: t2)
        // Status is a Reference column — the rename bulk-updates the column.
        let updated = try db.dbWriter.read { try Reference.fetchOne($0, id: id)! }
        XCTAssertEqual(updated.readingStatus, "Browsed")
        XCTAssertEqual(updated.dateModified, t2)
    }

    func testUpdateOptionNoOpDoesNotStampDefinitionOrValues() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let prop = try db.createPropertyDefinition(
            name: "Stage", type: .singleSelect,
            options: [SelectOption(value: "draft", color: "#111111")], now: t1)
        try db.setPropertyValue(referenceId: id, propertyId: prop.id!, value: "draft")
        try db.dbWriter.write {
            try $0.execute(
                sql: "UPDATE propertyValue SET dateModified = ? WHERE referenceId = ? AND propertyId = ?",
                arguments: [t1, id, prop.id!]
            )
        }

        let result = try db.updatePropertyOptionReportingChange(
            propertyId: prop.id!, option: "draft", newName: "draft", color: "#111111", now: t2)

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.definition.dateModified, t1)
        let valueStamp = try db.dbWriter.read {
            try Date.fetchOne(
                $0,
                sql: "SELECT dateModified FROM propertyValue WHERE referenceId = ? AND propertyId = ?",
                arguments: [id, prop.id!]
            )
        }
        XCTAssertEqual(valueStamp, t1)
    }

    // MARK: - Tags recolor / rename

    func testUpdateOptionRecolorsTagRow() throws {
        let db = try makeDB()
        let tags = try builtin(db, fieldKey: "tags")
        let newTagValue = try db.addPropertyOption(propertyId: tags.id!, value: "ml", color: "#111111")
        try db.updatePropertyOption(propertyId: tags.id!, option: newTagValue, newName: "machine-learning", color: "#ABCDEF", now: t1)
        let tag = try db.dbWriter.read { try Tag.fetchOne($0, id: Int64(newTagValue)!) }
        XCTAssertEqual(tag?.name, "machine-learning")
        XCTAssertEqual(tag?.color, "#ABCDEF")
        XCTAssertEqual(tag?.dateModified, t1)
    }

    func testUpdateOptionTagsRenameKeepsPivots() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let tags = try builtin(db, fieldKey: "tags")
        let tagVal = try db.addPropertyOption(propertyId: tags.id!, value: "ml")
        try db.setTags(forReference: id, tagIds: [Int64(tagVal)!])
        try db.updatePropertyOption(propertyId: tags.id!, option: tagVal, newName: "ML")
        // Rename must not disturb the pivot — tag id is the identity.
        let tags2 = try db.fetchTags(forReference: id)
        XCTAssertEqual(tags2.count, 1)
        XCTAssertEqual(tags2.first?.name, "ML")
    }

    func testUpdateOptionTagsDuplicateNameRejected() throws {
        let db = try makeDB()
        let tags = try builtin(db, fieldKey: "tags")
        _ = try db.addPropertyOption(propertyId: tags.id!, value: "existing")
        let target = try db.addPropertyOption(propertyId: tags.id!, value: "target")
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: tags.id!, option: target, newName: "existing")) { error in
            XCTAssertEqual(error as? PropertyOptionError, .duplicateValue("existing"))
        }
    }

    func testUpdateOptionTagsUnknownIdThrows() throws {
        let db = try makeDB()
        let tags = try builtin(db, fieldKey: "tags")
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: tags.id!, option: "999999", newName: "x")) { error in
            XCTAssertEqual(error as? PropertyOptionError, .optionNotFound)
        }
    }

    // MARK: - Combined-mutation atomicity

    func testUpdateOptionRenameRollsBackWhenBulkUpdateContextFails() throws {
        // A duplicate rename target must roll back the whole option mutation —
        // the optionsJSON stays intact, no partial rewrite of reference rows.
        let db = try makeDB()
        let id = try makeRef(db)
        let prop = try db.createPropertyDefinition(name: "Stage", type: .singleSelect, options: [SelectOption(value: "a", color: "#111111"), SelectOption(value: "b", color: "#222222")])
        try db.setPropertyValue(referenceId: id, propertyId: prop.id!, value: "a")
        XCTAssertThrowsError(try db.updatePropertyOption(propertyId: prop.id!, option: "a", newName: "b"))
        // optionsJSON unchanged, reference value unchanged.
        let updated = try db.fetchPropertyDefinition(id: prop.id!)!
        XCTAssertEqual(updated.options.map(\.value), ["a", "b"])
        let refValue = try db.dbWriter.read {
            try String.fetchOne($0, sql: "SELECT value FROM propertyValue WHERE referenceId = ? AND propertyId = ?", arguments: [id, prop.id!])
        }
        XCTAssertEqual(refValue, "a")
    }

    func testIsHexColorValidation() {
        XCTAssertTrue(AppDatabase.isHexColor("#ABCDEF"))
        XCTAssertTrue(AppDatabase.isHexColor("#012345"))
        XCTAssertFalse(AppDatabase.isHexColor("#ABC"))
        XCTAssertFalse(AppDatabase.isHexColor("ABCDEF"))
        XCTAssertFalse(AppDatabase.isHexColor("#GGGGGG"))
        XCTAssertFalse(AppDatabase.isHexColor("#ABCDEFF"))
    }
}
