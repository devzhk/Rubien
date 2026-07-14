import XCTest
import GRDB
@testable import RubienCore

/// §4.3 classification-table exhaustiveness + the pure payload-JSON decoder.
/// The table is the normative contract; this suite pins every seeded
/// `defaultFieldKey` to its intended class and confirms the code table and the
/// live seed agree.
final class ReferenceEditClassificationTests: XCTestCase {

    private func makeDB() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// The spec's §4.3 table transcribed independently of the implementation —
    /// all 30 seeded keys with their intended class.
    private static let expected: [String: BuiltinFieldClass] = [
        // writable-converted (validated / transformed)
        "referenceType": .writableConverted,
        "readingStatus": .writableConverted,
        "year": .writableConverted,
        "editors": .writableConverted,
        "translators": .writableConverted,
        "accessedDate": .writableConverted,
        // pivot exception
        "tags": .tagsPivot,
        // read-only reader telemetry
        "lastReadAt": .readOnly,
        "readCount": .readOnly,
        // writable-simple (verbatim string → same-named column)
        "doi": .writableSimple,
        "url": .writableSimple,
        "journal": .writableSimple,
        "volume": .writableSimple,
        "issue": .writableSimple,
        "pages": .writableSimple,
        "publisher": .writableSimple,
        "publisherPlace": .writableSimple,
        "edition": .writableSimple,
        "isbn": .writableSimple,
        "issn": .writableSimple,
        "eventTitle": .writableSimple,
        "eventPlace": .writableSimple,
        "genre": .writableSimple,
        "institution": .writableSimple,
        "number": .writableSimple,
        "collectionTitle": .writableSimple,
        "numberOfPages": .writableSimple,
        "language": .writableSimple,
        "pmid": .writableSimple,
        "pmcid": .writableSimple,
    ]

    func testExpectedTableCoversExactlyThirtyKeys() {
        XCTAssertEqual(Self.expected.count, 30)
    }

    /// Every key in the code table classifies exactly as the spec intends, and
    /// the two tables contain the same keys — no extras, none missing.
    func testCodeTableMatchesSpecTableExactly() {
        XCTAssertEqual(
            Set(ReferenceFieldClassification.table.keys),
            Set(Self.expected.keys),
            "code classification table keys diverge from the §4.3 spec table"
        )
        for (key, expectedClass) in Self.expected {
            XCTAssertEqual(
                ReferenceFieldClassification.table[key]?.fieldClass,
                expectedClass,
                "key '\(key)' has the wrong class"
            )
        }
    }

    /// Nullability flags: Type/Status are non-nullable, read-only cells carry
    /// clearable=false, everything else writable is clearable.
    func testClearabilityFlags() {
        XCTAssertEqual(ReferenceFieldClassification.table["referenceType"]?.clearable, false)
        XCTAssertEqual(ReferenceFieldClassification.table["readingStatus"]?.clearable, false)
        XCTAssertEqual(ReferenceFieldClassification.table["lastReadAt"]?.clearable, false)
        XCTAssertEqual(ReferenceFieldClassification.table["readCount"]?.clearable, false)
        XCTAssertEqual(ReferenceFieldClassification.table["year"]?.clearable, true)
        XCTAssertEqual(ReferenceFieldClassification.table["tags"]?.clearable, true)
        XCTAssertEqual(ReferenceFieldClassification.table["doi"]?.clearable, true)
        XCTAssertEqual(ReferenceFieldClassification.table["editors"]?.clearable, true)
    }

    /// The live seed must match the code table one-for-one: every seeded
    /// `defaultFieldKey` appears exactly once, and the table names no key the
    /// seed doesn't. This is the fail-closed guarantee's first line of defense.
    func testLiveSeedMatchesTableExactly() throws {
        let db = try makeDB()
        let seededKeys = try db.fetchAllPropertyDefinitions()
            .filter { $0.isDefault }
            .compactMap(\.defaultFieldKey)
        XCTAssertEqual(seededKeys.count, 30, "expected exactly 30 seeded built-ins")
        XCTAssertEqual(Set(seededKeys).count, 30, "seeded defaultFieldKeys must be unique")
        XCTAssertEqual(Set(seededKeys), Set(ReferenceFieldClassification.table.keys))
    }

    // MARK: - Payload decoding (pure)

    func testDecodeReplaceScalars() throws {
        let json = """
        {"Status": "Read", "Year": 2020, "Done": true, "Ratio": 1.5}
        """
        let decoded = try ReferenceEdit.decodeProperties(fromJSON: json)
        XCTAssertEqual(decoded["Status"], .replace(.string("Read")))
        XCTAssertEqual(decoded["Year"], .replace(.integer(2020)))
        XCTAssertEqual(decoded["Done"], .replace(.bool(true)))
        XCTAssertEqual(decoded["Ratio"], .replace(.decimal(1.5)))
    }

    func testDecodeReplaceArray() throws {
        let decoded = try ReferenceEdit.decodeProperties(fromJSON: #"{"7": ["ml", "nlp"]}"#)
        XCTAssertEqual(decoded["7"], .replace(.array([.string("ml"), .string("nlp")])))
    }

    func testDecodeClearIsNull() throws {
        let decoded = try ReferenceEdit.decodeProperties(fromJSON: #"{"Themes": null}"#)
        XCTAssertEqual(decoded["Themes"], .clear)
    }

    func testDecodeAddRemove() throws {
        let decoded = try ReferenceEdit.decodeProperties(fromJSON: #"{"Tags": {"add": ["12"], "remove": ["3"]}}"#)
        XCTAssertEqual(decoded["Tags"], .addRemove(add: [.string("12")], remove: [.string("3")]))
    }

    func testDecodeAddOnly() throws {
        let decoded = try ReferenceEdit.decodeProperties(fromJSON: #"{"Tags": {"add": ["12"]}}"#)
        XCTAssertEqual(decoded["Tags"], .addRemove(add: [.string("12")], remove: []))
    }

    /// A JSON `true` and a JSON `1` must decode to *distinct* payload values —
    /// the CFBoolean-vs-CFNumber discriminator, the whole reason for the
    /// CoreFoundation import.
    func testDecodeDistinguishesBoolFromOne() throws {
        let decoded = try ReferenceEdit.decodeProperties(fromJSON: #"{"a": true, "b": 1}"#)
        XCTAssertEqual(decoded["a"], .replace(.bool(true)))
        XCTAssertEqual(decoded["b"], .replace(.integer(1)))
        XCTAssertNotEqual(decoded["a"], decoded["b"])
    }

    func testDecodeRejectsNonObjectRoot() {
        XCTAssertThrowsError(try ReferenceEdit.decodeProperties(fromJSON: "[1,2,3]")) { error in
            guard case ReferenceEditError.invalidPayload = error else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
        }
    }

    func testDecodeRejectsUnknownObjectKeys() {
        XCTAssertThrowsError(try ReferenceEdit.decodeProperties(fromJSON: #"{"Tags": {"append": ["1"]}}"#)) { error in
            guard case ReferenceEditError.invalidPayload(let key, _) = error else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
            XCTAssertEqual(key, "Tags")
        }
    }

    func testDecodeRejectsEmptyObject() {
        XCTAssertThrowsError(try ReferenceEdit.decodeProperties(fromJSON: #"{"Tags": {}}"#)) { error in
            guard case ReferenceEditError.invalidPayload = error else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
        }
    }

    func testDecodeRejectsNonStringAddElement() {
        XCTAssertThrowsError(try ReferenceEdit.decodeProperties(fromJSON: #"{"Tags": {"add": [12]}}"#)) { error in
            guard case ReferenceEditError.invalidPayload = error else {
                return XCTFail("expected invalidPayload, got \(error)")
            }
        }
    }
}
