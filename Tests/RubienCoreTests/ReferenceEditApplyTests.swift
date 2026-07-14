import XCTest
import GRDB
@testable import RubienCore

/// `applyReferenceEdit` — spec §4.2–§4.5: selector resolution, conflict
/// detection, the §4.4 value-validation matrix, atomicity, and the no-op /
/// single-`now` timestamp rules (including the Tags pivot diff).
final class ReferenceEditApplyTests: XCTestCase {

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private func makeRef(_ db: AppDatabase, title: String = "ref") throws -> Int64 {
        var ref = Reference(title: title)
        _ = try db.saveReference(&ref)
        return ref.id!
    }

    private func fetch(_ db: AppDatabase, _ id: Int64) throws -> Reference {
        try db.dbWriter.read { try Reference.fetchOne($0, id: id)! }
    }

    private func propId(_ db: AppDatabase, fieldKey: String) throws -> Int64 {
        try db.fetchAllPropertyDefinitions().first { $0.defaultFieldKey == fieldKey }!.id!
    }

    private func makeCustom(
        _ db: AppDatabase,
        name: String,
        type: PropertyType,
        options: [String] = []
    ) throws -> Int64 {
        let opts = options.enumerated().map { SelectOption(value: $0.element, color: "#00000\($0.offset % 10)") }
        return try db.createPropertyDefinition(name: name, type: type, options: opts).id!
    }

    private func tagId(_ db: AppDatabase, _ name: String) throws -> Int64 {
        var tag = Tag(name: name)
        try db.saveTag(&tag)
        return tag.id!
    }

    private func pivotDate(_ db: AppDatabase, ref: Int64, tag: Int64) throws -> Date? {
        try db.dbWriter.read {
            try Date.fetchOne($0, sql: "SELECT dateModified FROM referenceTag WHERE referenceId = ? AND tagId = ?", arguments: [ref, tag])
        }
    }

    // MARK: - Built-in routing: writable-simple / writable-converted

    func testWritableSimpleByName() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Journal": .replace(.string("Nature"))]))
        XCTAssertEqual(try fetch(db, id).journal, "Nature")
    }

    func testWritableSimpleByHiddenBuiltinNotExposedAsTopLevelFlag() throws {
        // PMID / Genre / Event are seeded built-ins with no top-level CLI flag —
        // the payload is the only door. This is the feature's whole point.
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: [
            "PMID": .replace(.string("123456")),
            "Genre": .replace(.string("Doctoral dissertation")),
        ]))
        let ref = try fetch(db, id)
        XCTAssertEqual(ref.pmid, "123456")
        XCTAssertEqual(ref.genre, "Doctoral dissertation")
    }

    func testWritableSimpleClear() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["DOI": .replace(.string("10.1/x"))]))
        XCTAssertEqual(try fetch(db, id).doi, "10.1/x")
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["DOI": .clear]))
        XCTAssertNil(try fetch(db, id).doi)
    }

    func testWritableSimpleRejectsNonString() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        assertInvalidValue(key: "Journal") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Journal": .replace(.integer(3))]))
        }
    }

    func testWritableSimpleRejectsEmptyString() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        assertInvalidValue(key: "Journal") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Journal": .replace(.string(""))]))
        }
    }

    func testYearAcceptsIntegerRejectsDecimalAndString() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Year": .replace(.integer(1999))]))
        XCTAssertEqual(try fetch(db, id).year, 1999)
        assertInvalidValue(key: "Year") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Year": .replace(.decimal(1999.5))]))
        }
        assertInvalidValue(key: "Year") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Year": .replace(.string("1999"))]))
        }
    }

    func testYearClear() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Year": .replace(.integer(2001))]))
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Year": .clear]))
        XCTAssertNil(try fetch(db, id).year)
    }

    func testEditorsTranslatorsRoundTripThroughEncodeNames() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: [
            "Editors": .replace(.string("Smith, John; Doe, Jane")),
            "Translators": .replace(.string("García, María")),
        ]))
        let ref = try fetch(db, id)
        // Stored as JSON-encoded AuthorName arrays — verbatim storage would
        // corrupt them. Compare decoded structure, not raw JSON: JSONEncoder's
        // key order is an implementation detail.
        XCTAssertNotNil(ref.editors)
        XCTAssertEqual(ref.parsedEditors, [
            AuthorName(given: "John", family: "Smith"),
            AuthorName(given: "Jane", family: "Doe"),
        ])
        XCTAssertEqual(ref.parsedTranslators, [AuthorName(given: "María", family: "García")])
    }

    func testEditorsClear() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Editors": .replace(.string("A, B"))]))
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Editors": .clear]))
        XCTAssertNil(try fetch(db, id).editors)
    }

    func testAccessedDateAcceptsYMDLiteralRejectsBadDate() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Accessed Date": .replace(.string("2026-07-14"))]))
        XCTAssertEqual(try fetch(db, id).accessedDate, "2026-07-14")   // literal string, per markdown importer
        assertInvalidValue(key: "Accessed Date") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Accessed Date": .replace(.string("2026-13-40"))]))
        }
        assertInvalidValue(key: "Accessed Date") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Accessed Date": .replace(.string("2026-07-14T00:00:00Z"))]))
        }
    }

    // MARK: - Type / Status (non-nullable, validated)

    func testTypeValidatesLabelAndRejectsNull() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Type": .replace(.string("Book"))]))
        XCTAssertEqual(try fetch(db, id).referenceType, .book)
        assertInvalidValue(key: "Type") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Type": .replace(.string("Nonsense"))]))
        }
        // payload null → non-nullable error, distinct from unknown-field.
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: ["Type": .clear]))) { error in
            guard case ReferenceEditError.nonNullableBuiltin = error else {
                return XCTFail("expected nonNullableBuiltin, got \(error)")
            }
        }
    }

    func testStatusLiveValidatedAndRejectsNull() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Status": .replace(.string("Skimmed"))]))
        XCTAssertEqual(try fetch(db, id).readingStatus, "Skimmed")
        assertInvalidValue(key: "Status") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Status": .replace(.string("doing"))]))
        }
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: ["Status": .clear]))) { error in
            guard case ReferenceEditError.nonNullableBuiltin = error else {
                return XCTFail("expected nonNullableBuiltin, got \(error)")
            }
        }
    }

    func testStatusAcceptsUserAddedOptionLive() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let statusId = try propId(db, fieldKey: "readingStatus")
        _ = try db.addPropertyOption(propertyId: statusId, value: "Annotating", color: "#123456")
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Status": .replace(.string("Annotating"))]))
        XCTAssertEqual(try fetch(db, id).readingStatus, "Annotating")
    }

    // MARK: - Read-only telemetry

    func testReadOnlyBuiltinsRejected() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        for name in ["Last Read", "Read Count"] {
            XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: [name: .replace(.integer(5))]))) { error in
                guard case ReferenceEditError.readOnlyBuiltin = error else {
                    return XCTFail("expected readOnlyBuiltin for \(name), got \(error)")
                }
            }
        }
        // No shadow propertyValue row was written.
        let count = try db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM propertyValue") ?? 0 }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Custom property value validation (§4.4)

    func testCustomStringNumberDateUrlCheckbox() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let sId = try makeCustom(db, name: "Note", type: .string)
        let nId = try makeCustom(db, name: "Count", type: .number)
        let dId = try makeCustom(db, name: "Due", type: .date)
        let uId = try makeCustom(db, name: "Home", type: .url)
        let cId = try makeCustom(db, name: "Done", type: .checkbox)

        try db.applyReferenceEdit(id: id, edit: .init(properties: [
            String(sId): .replace(.string("hi")),
            String(nId): .replace(.integer(42)),
            String(dId): .replace(.string("2026-01-02")),
            String(uId): .replace(.string("https://example.com")),
            String(cId): .replace(.bool(true)),
        ]))
        let values = try storedValues(db, refId: id)
        XCTAssertEqual(values[sId], "hi")
        XCTAssertEqual(values[nId], "42")                       // canonical integer string
        XCTAssertEqual(values[dId], "2026-01-02T00:00:00Z")     // ISO-8601 UTC midnight
        XCTAssertEqual(values[uId], "https://example.com")
        XCTAssertEqual(values[cId], "true")
    }

    func testCustomNumberRejectsDecimalStringBool() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let nId = try makeCustom(db, name: "Count", type: .number)
        assertInvalidValue(key: String(nId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(nId): .replace(.decimal(1.5))]))
        }
        assertInvalidValue(key: String(nId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(nId): .replace(.string("3"))]))
        }
        assertInvalidValue(key: String(nId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(nId): .replace(.bool(true))]))
        }
    }

    func testCustomCheckboxRejectsOneAndString() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let cId = try makeCustom(db, name: "Done", type: .checkbox)
        assertInvalidValue(key: String(cId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(cId): .replace(.integer(1))]))
        }
        assertInvalidValue(key: String(cId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(cId): .replace(.string("true"))]))
        }
    }

    func testCustomUrlRejectsRelativeAndOtherScheme() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let uId = try makeCustom(db, name: "Home", type: .url)
        assertInvalidValue(key: String(uId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(uId): .replace(.string("/relative"))]))
        }
        assertInvalidValue(key: String(uId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(uId): .replace(.string("ftp://x.com"))]))
        }
    }

    func testCustomSingleSelectRejectsUnknownOption() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let sId = try makeCustom(db, name: "Stage", type: .singleSelect, options: ["draft", "final"])
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(sId): .replace(.string("draft"))]))
        XCTAssertEqual(try storedValues(db, refId: id)[sId], "draft")
        assertInvalidValue(key: String(sId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(sId): .replace(.string("nope"))]))
        }
    }

    func testCustomMultiSelectReplaceCanonicalizesAndCoercesSingle() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml", "nlp", "vision"])
        // Duplicates removed (first wins), order preserved.
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("nlp"), .string("ml"), .string("nlp")]))]))
        XCTAssertEqual(PropertyValue.decodeMultiSelect(try storedValues(db, refId: id)[mId] ?? ""), ["nlp", "ml"])
        // Single string coerces to a one-element set.
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.string("vision"))]))
        XCTAssertEqual(PropertyValue.decodeMultiSelect(try storedValues(db, refId: id)[mId] ?? ""), ["vision"])
    }

    func testCustomMultiSelectEmptyArrayDeletesRow() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml", "nlp"])
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("ml")]))]))
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([]))]))
        XCTAssertNil(try storedValues(db, refId: id)[mId], "empty array ≡ null ≡ row deletion; \"[]\" never stored")
    }

    func testCustomMultiSelectAddRemove() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml", "nlp", "vision"])
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("ml"), .string("nlp")]))]))
        // add applies before remove.
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .addRemove(add: [.string("vision")], remove: [.string("ml")])]))
        XCTAssertEqual(PropertyValue.decodeMultiSelect(try storedValues(db, refId: id)[mId] ?? ""), ["nlp", "vision"])
    }

    func testCustomMultiSelectRejectsNonStringAndUnknownOption() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml"])
        assertInvalidValue(key: String(mId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.integer(1)]))]))
        }
        assertInvalidValue(key: String(mId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("unknown")]))]))
        }
    }

    func testCustomAddRemoveRejectedOnNonMultiSelect() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let sId = try makeCustom(db, name: "Note", type: .string)
        assertInvalidValue(key: String(sId)) {
            try db.applyReferenceEdit(id: id, edit: .init(properties: [String(sId): .addRemove(add: [.string("x")], remove: [])]))
        }
    }

    // MARK: - Selector resolution + error taxonomy

    func testResolveByIdAndName() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml"])
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("ml")]))]))
        XCTAssertEqual(PropertyValue.decodeMultiSelect(try storedValues(db, refId: id)[mId] ?? ""), ["ml"])
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Modality": .clear]))
        XCTAssertNil(try storedValues(db, refId: id)[mId])
    }

    func testUnresolvedSelectorsCollected() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: [
            "Nope": .replace(.string("x")),
            "AlsoMissing": .replace(.string("y")),
        ]))) { error in
            guard case ReferenceEditError.unresolvedSelectors(let keys) = error else {
                return XCTFail("expected unresolvedSelectors, got \(error)")
            }
            XCTAssertEqual(keys, ["AlsoMissing", "Nope"])   // sorted, both reported
        }
    }

    func testColumnFieldsWithoutSeededDefinitionAreUnresolved() throws {
        // title/authors/abstract/notes are Reference columns with no seeded
        // definition — a payload key naming them is unresolved-selectors.
        let db = try makeDB()
        let id = try makeRef(db)
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: ["abstract": .replace(.string("x"))]))) { error in
            guard case ReferenceEditError.unresolvedSelectors = error else {
                return XCTFail("expected unresolvedSelectors, got \(error)")
            }
        }
    }

    func testInt64OverflowSelectorIsInvalidNotNameFallback() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: ["99999999999999999999": .replace(.string("x"))]))) { error in
            guard case ReferenceEditError.invalidSelector(let key) = error else {
                return XCTFail("expected invalidSelector, got \(error)")
            }
            XCTAssertEqual(key, "99999999999999999999")
        }
    }

    func testDuplicateResolutionError() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml"])
        // Address the same property twice — once by id, once by name.
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: [
            String(mId): .replace(.array([.string("ml")])),
            "Modality": .clear,
        ]))) { error in
            guard case ReferenceEditError.duplicateResolution(let pid, _) = error else {
                return XCTFail("expected duplicateResolution, got \(error)")
            }
            XCTAssertEqual(pid, mId)
        }
    }

    func testReferenceNotFound() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.applyReferenceEdit(id: 999, edit: .init(properties: ["Journal": .replace(.string("x"))]))) { error in
            guard case ReferenceEditError.referenceNotFound(999) = error else {
                return XCTFail("expected referenceNotFound, got \(error)")
            }
        }
    }

    func testUnknownClearFieldRejected() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(clearFields: ["bogus"]))) { error in
            guard case ReferenceEditError.unknownField = error else {
                return XCTFail("expected unknownField, got \(error)")
            }
        }
    }

    // MARK: - Conflict detection (post-canonicalization)

    func testConflictTopLevelValueVsPayloadValue() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        assertConflict {
            try db.applyReferenceEdit(id: id, edit: .init(doi: "10.1/a", properties: ["DOI": .replace(.string("10.1/b"))]))
        }
    }

    func testConflictTopLevelValueVsPayloadNull() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        assertConflict {
            try db.applyReferenceEdit(id: id, edit: .init(year: 2000, properties: ["Year": .clear]))
        }
    }

    func testConflictClearFieldsVsPayloadValueCaseInsensitive() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        // clearFields "DOI" (upper) lowercases to "doi"; payload "DOI" resolves
        // to defaultFieldKey "doi" → same canonical column.
        assertConflict {
            try db.applyReferenceEdit(id: id, edit: .init(clearFields: ["DOI"], properties: ["DOI": .replace(.string("10.1/z"))]))
        }
    }

    func testNoConflictForDistinctCanonicalColumns() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        // Top-level doi + payload Journal → different columns, no conflict.
        try db.applyReferenceEdit(id: id, edit: .init(doi: "10.1/a", properties: ["Journal": .replace(.string("N"))]))
        let ref = try fetch(db, id)
        XCTAssertEqual(ref.doi, "10.1/a")
        XCTAssertEqual(ref.journal, "N")
    }

    // MARK: - Atomicity

    func testFailingPayloadEntryRollsBackMetadataEdit() throws {
        let db = try makeDB()
        let id = try makeRef(db, title: "original")
        // Valid top-level title change + an invalid payload entry → whole call
        // rolls back; the title must be untouched.
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(
            title: "changed",
            properties: ["Year": .replace(.string("not-an-int"))]
        )))
        XCTAssertEqual(try fetch(db, id).title, "original")
    }

    func testFailingCustomEntryRollsBackEarlierCustomWrite() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let okId = try makeCustom(db, name: "Note", type: .string)
        let badId = try makeCustom(db, name: "Count", type: .number)
        XCTAssertThrowsError(try db.applyReferenceEdit(id: id, edit: .init(properties: [
            String(okId): .replace(.string("kept?")),
            String(badId): .replace(.string("not-int")),
        ])))
        XCTAssertNil(try storedValues(db, refId: id)[okId], "the valid entry must not persist when a sibling entry fails")
    }

    // MARK: - No-op / timestamp

    func testNoOpColumnWriteLeavesReferenceRowUntouched() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Journal": .replace(.string("N"))]), now: t1)
        let before = try fetch(db, id)
        // Re-setting the same value must write nothing (no dateModified churn).
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Journal": .replace(.string("N"))]), now: t2)
        let after = try fetch(db, id)
        XCTAssertEqual(after.dateModified, before.dateModified)
    }

    func testChangedReferenceRowStampsCapturedNow() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Journal": .replace(.string("N"))]), now: t1)
        XCTAssertEqual(try fetch(db, id).dateModified, t1)
    }

    func testNoOpPropertyValueWriteLeavesRowUntouched() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let sId = try makeCustom(db, name: "Note", type: .string)
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(sId): .replace(.string("x"))]), now: t1)
        let before = try propValueDate(db, refId: id, propId: sId)
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(sId): .replace(.string("x"))]), now: t2)
        XCTAssertEqual(try propValueDate(db, refId: id, propId: sId), before)
    }

    func testChangedPropertyValueStampsNowOnUpdate() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let sId = try makeCustom(db, name: "Note", type: .string)
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(sId): .replace(.string("x"))]), now: t1)
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(sId): .replace(.string("y"))]), now: t2)
        XCTAssertEqual(try propValueDate(db, refId: id, propId: sId), t2)
    }

    func testCustomMultiSelectExactOrderedArrayIsNoOp() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml", "nlp"])
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("ml"), .string("nlp")]))]), now: t1)
        let before = try propValueDate(db, refId: id, propId: mId)
        // Same array, same order → no write.
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("ml"), .string("nlp")]))]), now: t2)
        XCTAssertEqual(try propValueDate(db, refId: id, propId: mId), before)
    }

    func testCustomMultiSelectReorderedArrayIsNotNoOp() throws {
        // Custom multiSelects compare exact ordered — reordering IS a change.
        let db = try makeDB()
        let id = try makeRef(db)
        let mId = try makeCustom(db, name: "Modality", type: .multiSelect, options: ["ml", "nlp"])
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("ml"), .string("nlp")]))]), now: t1)
        try db.applyReferenceEdit(id: id, edit: .init(properties: [String(mId): .replace(.array([.string("nlp"), .string("ml")]))]), now: t2)
        XCTAssertEqual(try propValueDate(db, refId: id, propId: mId), t2)
        XCTAssertEqual(PropertyValue.decodeMultiSelect(try storedValues(db, refId: id)[mId] ?? ""), ["nlp", "ml"])
    }

    // MARK: - Tags pivot diff

    func testTagsReplaceRoutesToPivotNotPropertyValue() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let a = try tagId(db, "a")
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Tags": .replace(.array([.string(String(a))]))]))
        XCTAssertEqual(Set(try db.fetchTags(forReference: id).compactMap(\.id)), [a])
        let pvRows = try db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM propertyValue") ?? 0 }
        XCTAssertEqual(pvRows, 0)
    }

    func testTagsUnknownIdRejected() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        assertInvalidValue(key: "Tags") {
            try db.applyReferenceEdit(id: id, edit: .init(properties: ["Tags": .replace(.array([.string("999999")]))]))
        }
    }

    func testTagsNullClearsAll() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let a = try tagId(db, "a")
        let b = try tagId(db, "b")
        try db.setTags(forReference: id, tagIds: [a, b])
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Tags": .clear]))
        XCTAssertEqual(try db.fetchTags(forReference: id).count, 0)
    }

    /// Set-equality: the same membership in a different order is a no-op that
    /// touches NO pivots (their timestamps stay put), and never touches the
    /// reference row.
    func testUnchangedTagSetTouchesNoPivots() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let a = try tagId(db, "a")
        let b = try tagId(db, "b")
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Tags": .replace(.array([.string(String(a)), .string(String(b))]))]), now: t1)
        let refBefore = try fetch(db, id)
        let aDate = try pivotDate(db, ref: id, tag: a)
        let bDate = try pivotDate(db, ref: id, tag: b)
        // Same set, reversed order, different `now`.
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Tags": .replace(.array([.string(String(b)), .string(String(a))]))]), now: t2)
        XCTAssertEqual(try pivotDate(db, ref: id, tag: a), aDate, "unchanged pivot must keep its timestamp")
        XCTAssertEqual(try pivotDate(db, ref: id, tag: b), bDate)
        XCTAssertEqual(try fetch(db, id).dateModified, refBefore.dateModified, "Tags-only edit must not stamp the reference row")
    }

    /// Partial change: only inserted/removed pivots move; the untouched pivot
    /// keeps its old timestamp, the inserted one gets the new `now`.
    func testPartiallyChangedTagSetStampsOnlyChangedPivots() throws {
        let db = try makeDB()
        let id = try makeRef(db)
        let a = try tagId(db, "a")
        let b = try tagId(db, "b")
        let c = try tagId(db, "c")
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Tags": .replace(.array([.string(String(a)), .string(String(b))]))]), now: t1)
        let bDate = try pivotDate(db, ref: id, tag: b)
        // {a,b} → {b,c}: a removed, c added, b unchanged.
        try db.applyReferenceEdit(id: id, edit: .init(properties: ["Tags": .addRemove(add: [.string(String(c))], remove: [.string(String(a))])]), now: t2)
        XCTAssertEqual(Set(try db.fetchTags(forReference: id).compactMap(\.id)), [b, c])
        XCTAssertEqual(try pivotDate(db, ref: id, tag: b), bDate, "unchanged pivot keeps its timestamp")
        XCTAssertEqual(try pivotDate(db, ref: id, tag: c), t2, "new pivot gets the captured now")
        XCTAssertNil(try pivotDate(db, ref: id, tag: a))
    }

    // MARK: - Helpers

    private func storedValues(_ db: AppDatabase, refId: Int64) throws -> [Int64: String] {
        try db.dbWriter.read { conn in
            var map: [Int64: String] = [:]
            let rows = try PropertyValue.filter(PropertyValue.Columns.referenceId == refId).fetchAll(conn)
            for row in rows { if let v = row.value { map[row.propertyId] = v } }
            return map
        }
    }

    private func propValueDate(_ db: AppDatabase, refId: Int64, propId: Int64) throws -> Date? {
        try db.dbWriter.read {
            try Date.fetchOne($0, sql: "SELECT dateModified FROM propertyValue WHERE referenceId = ? AND propertyId = ?", arguments: [refId, propId])
        }
    }

    private func assertInvalidValue(key expectedKey: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ReferenceEditError.invalidValue(let key, _) = error else {
                return XCTFail("expected invalidValue, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(key, expectedKey, file: file, line: line)
        }
    }

    private func assertConflict(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ReferenceEditError.conflict = error else {
                return XCTFail("expected conflict, got \(error)", file: file, line: line)
            }
        }
    }
}
