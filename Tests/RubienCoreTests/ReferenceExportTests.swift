import GRDB
import XCTest
@testable import RubienCore

final class ReferenceExportTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    func testExplicitIDsPreserveOrderDeduplicateAndRejectMissingIDs() throws {
        let database = try makeDatabase()
        var first = Reference(title: "First")
        var second = Reference(title: "Second")
        var third = Reference(title: "Third")
        try database.saveReference(&first)
        try database.saveReference(&second)
        try database.saveReference(&third)

        let service = ReferenceExportService(database: database)
        let artifact = try service.export(ReferenceExportRequest(
            format: .json,
            scope: .ids([third.id!, first.id!, third.id!])
        ))
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifact.data) as? [[String: Any]]
        )
        XCTAssertEqual(rows.compactMap { ($0["id"] as? NSNumber)?.int64Value }, [third.id!, first.id!])

        XCTAssertThrowsError(try service.export(ReferenceExportRequest(
            format: .json,
            scope: .ids([third.id!, 9_999, first.id!, 8_888])
        ))) { error in
            XCTAssertEqual(
                error as? ReferenceExportError,
                .unresolvedReferenceIDs([9_999, 8_888])
            )
        }
        XCTAssertThrowsError(try service.export(ReferenceExportRequest(
            format: .json,
            scope: .ids([])
        ))) { error in
            XCTAssertEqual(error as? ReferenceExportError, .emptySelection)
        }
    }

    func testExplicitJSONExportCrossesSQLiteParameterChunkBoundary() throws {
        let database = try makeDatabase()
        var ids: [Int64] = []
        try database.dbWriter.write { db in
            for index in 0..<501 {
                var reference = Reference(title: "Chunk \(index)")
                try reference.insert(db)
                ids.append(try XCTUnwrap(reference.id))
            }
        }

        let requested = Array(ids.reversed())
        let artifact = try ReferenceExportService(database: database).export(
            ReferenceExportRequest(format: .json, scope: .ids(requested))
        )
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifact.data) as? [[String: Any]]
        )
        XCTAssertEqual(
            rows.compactMap { ($0["id"] as? NSNumber)?.int64Value },
            requested
        )
    }

    func testJSONPreservesCustomPropertiesAndMaterializedPDFContract() throws {
        let database = try makeDatabase()
        var reference = Reference(
            title: "JSON contract",
            siteName: "Example",
            readingStatus: ReadingStatus.read,
            readCount: 3
        )
        try database.saveReference(&reference)

        var property = PropertyDefinition(name: "Rating", type: .string)
        try database.savePropertyDefinition(&property)
        try database.setPropertyValue(
            referenceId: reference.id!,
            propertyId: property.id!,
            value: "Excellent"
        )
        try database.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(
                    referenceId, localFilename, contentHash, assetVersion,
                    materializedAt, lastOpenedAt
                ) VALUES (?, ?, ?, 1, ?, ?)
                """, arguments: [reference.id!, "paper.pdf", "hash", Date(), Date()])
        }

        let artifact = try ReferenceExportService(database: database).export(
            ReferenceExportRequest(format: .json, scope: .ids([reference.id!]))
        )
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifact.data) as? [[String: Any]]
        )
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["siteName"] as? String, "Example")
        XCTAssertEqual(row["pdfPath"] as? String, "paper.pdf")
        XCTAssertEqual(row["readCount"] as? Int, 3)
        XCTAssertNil(row["lastReadAt"])
        let custom = try XCTUnwrap(row["customProperties"] as? [[String: Any]])
        XCTAssertEqual(custom.first?["name"] as? String, "Rating")
        XCTAssertEqual(custom.first?["value"] as? String, "Excellent")
    }

    func testBibTeXKeysStayStableAcrossScopesAndContinuePastZ() throws {
        let database = try makeDatabase()
        var references: [Reference] = []
        for index in 0..<28 {
            var reference = Reference(
                title: "Collision \(index)",
                authors: [AuthorName(given: "Ada", family: "Smith")],
                year: 2025,
                dateAdded: Date(timeIntervalSince1970: TimeInterval(1_000 - index))
            )
            try database.saveReference(&reference)
            references.append(reference)
        }

        let service = ReferenceExportService(database: database)
        let all = try service.export(ReferenceExportRequest(format: .bibtex, scope: .all))
        let selected = try service.export(ReferenceExportRequest(
            format: .bibtex,
            scope: .ids([references[27].id!])
        ))
        let allText = String(decoding: all.data, as: UTF8.self)
        let selectedText = String(decoding: selected.data, as: UTF8.self)
        XCTAssertTrue(allText.contains("@article{Smith2025a,"))
        XCTAssertTrue(allText.contains("@article{Smith2025z,"))
        XCTAssertTrue(allText.contains("@article{Smith2025aa,"))
        XCTAssertTrue(allText.contains("@article{Smith2025ab,"))
        XCTAssertTrue(selectedText.contains("@article{Smith2025ab,"))
    }

    func testBibTeXAndRISApplyExtendedMappingsAndSafeEscaping() throws {
        let database = try makeDatabase()
        var reference = Reference(
            title: "RNA_seq {A} & 50%",
            authors: [AuthorName(given: "Grace", family: "Hopper")],
            year: 2024,
            pages: "123--130",
            abstract: "line one\nTY  - INJECTED",
            referenceType: .conferencePaper,
            publisher: "Press",
            publisherPlace: "   ",
            editors: Reference.encodeNames([AuthorName(given: "Edsger", family: "Dijkstra")]),
            accessedDate: "2026-08-04",
            issuedMonth: 7,
            issuedDay: 2,
            eventTitle: "Compiler Conf",
            eventPlace: "New York",
            language: "en",
            pmid: "123"
        )
        try database.saveReference(&reference)
        let service = ReferenceExportService(database: database)

        let bib = try service.export(ReferenceExportRequest(
            format: .bibtex,
            scope: .ids([reference.id!])
        ))
        let bibText = String(decoding: bib.data, as: UTF8.self)
        XCTAssertTrue(bibText.contains("@inproceedings{Hopper2024,"))
        XCTAssertTrue(bibText.contains(#"title = {{RNA\_seq \{A\} \& 50\%}},"#))
        XCTAssertTrue(bibText.contains("booktitle = {Compiler Conf},"))
        XCTAssertTrue(bibText.contains("address = {New York},"))
        XCTAssertTrue(bibText.contains("month = jul,"))

        let ris = try service.export(ReferenceExportRequest(
            format: .ris,
            scope: .ids([reference.id!])
        ))
        let risText = String(decoding: ris.data, as: UTF8.self)
        XCTAssertTrue(risText.contains("SP  - 123\nEP  - 130"))
        XCTAssertTrue(risText.contains("DA  - 2024/07/02"))
        XCTAssertTrue(risText.contains("CY  - New York"))
        XCTAssertTrue(risText.contains("AB  - line one TY  - INJECTED"))
        XCTAssertEqual(risText.components(separatedBy: "\nTY  - INJECTED").count, 1)
    }

    func testSavedViewScopeUsesSharedFilterAndSortPipeline() throws {
        let database = try makeDatabase()
        var older = Reference(title: "Older", year: 2020)
        var newer = Reference(title: "Newer", year: 2024)
        try database.saveReference(&older)
        try database.saveReference(&newer)
        var view = DatabaseView(
            name: "Recent years",
            filters: [ViewFilter(
                target: .builtin(.year),
                op: .greaterThan,
                value: .number(2021)
            )],
            sorts: [ViewSort(target: .builtin(.title), ascending: true)]
        )
        try database.saveDatabaseView(&view)

        let listRows = try database.fetchReferences(savedViewID: view.id!)
        let artifact = try ReferenceExportService(database: database).export(
            ReferenceExportRequest(format: .json, scope: .savedView(view.id!))
        )
        let exported = try XCTUnwrap(
            JSONSerialization.jsonObject(with: artifact.data) as? [[String: Any]]
        )
        XCTAssertEqual(listRows.map(\.id), [newer.id])
        XCTAssertEqual(
            exported.compactMap { ($0["id"] as? NSNumber)?.int64Value },
            listRows.compactMap(\.id)
        )
    }
}
