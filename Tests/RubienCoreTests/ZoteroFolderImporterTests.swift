import XCTest
import GRDB
@testable import RubienCore

final class ZoteroFolderImporterTests: XCTestCase {

    // MARK: - Helpers

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(path: ":memory:"))
    }

    /// Build a fake Zotero-export folder in a temporary directory. Returns the folder URL.
    /// The caller is responsible for passing it to `FileManager.removeItem(at:)` when done.
    private func makeFakeZoteroFolder(
        name: String,
        bibtex: String,
        pdfs: [String: Data]
    ) throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienZoteroImportTests-\(UUID().uuidString)")
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let bibURL = tempRoot.appendingPathComponent("\(name).bib")
        try bibtex.write(to: bibURL, atomically: true, encoding: .utf8)

        for (relPath, data) in pdfs {
            let dest = tempRoot.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: dest)
        }
        return tempRoot
    }

    private func makeFakeSourcePDF(name: String, data: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienZoteroImportTests-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Track PDFs copied into Rubien's global store so we can clean up after each test.
    private var copiedPDFPaths: [String] = []

    override func tearDownWithError() throws {
        for path in copiedPDFPaths {
            let url = PDFService.pdfURL(for: path)
            try? FileManager.default.removeItem(at: url)
        }
        copiedPDFPaths.removeAll()
        try super.tearDownWithError()
    }

    private func runImport(
        folder: URL,
        db: AppDatabase,
        target: ZoteroImportPropertyTarget?
    ) throws -> ZoteroFolderImporter.Result {
        let result = try ZoteroFolderImporter.importFolder(
            at: folder,
            db: db,
            propertyTarget: target
        )
        let refs = try db.fetchAllReferences()
        // Post-B8: the importer writes pdfCache rows. Pull every cached
        // filename so tearDownWithError can clean them up.
        for ref in refs {
            if let id = ref.id, let filename = try db.pdfFilename(for: id) {
                copiedPDFPaths.append(filename)
            }
        }
        return result
    }

    /// Convenience for tests asserting that a Reference has an attached PDF.
    /// Pre-B8 these called `ref.pdfPath`; post-B8 we look it up via cache.
    private func cachedFilename(for ref: Reference, db: AppDatabase) throws -> String? {
        guard let id = ref.id else { return nil }
        return try db.pdfFilename(for: id)
    }

    // MARK: - Tests

    func testImportFolderAttachesPDFsAndTagsReferences() throws {
        let db = try makeDatabase()
        let bibtex = """
        @book{a,
            title = {Paper A},
            author = {Doe, Jane},
            file = {PDF:files/1/a.pdf:application/pdf},
        }
        @article{b,
            title = {Paper B},
            author = {Roe, John},
            file = {PDF:files/2/b.pdf:application/pdf},
        }
        """
        let folder = try makeFakeZoteroFolder(
            name: "RL",
            bibtex: bibtex,
            pdfs: [
                "files/1/a.pdf": Data("fake pdf A".utf8),
                "files/2/b.pdf": Data("fake pdf B".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        // Stamp into the built-in Tags property.
        let tagsProp = try XCTUnwrap(db.findPropertyDefinition(byName: "Tags"))
        let target = ZoteroImportPropertyTarget(propertyId: tagsProp.id!, value: "RL")

        let result = try runImport(folder: folder, db: db, target: target)

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.attached, 2)
        XCTAssertEqual(result.missingPDFs, [])
        XCTAssertEqual(result.duplicatesSkipped, 0)

        let refs = try db.fetchAllReferences().sorted { ($0.title ?? "") < ($1.title ?? "") }
        XCTAssertEqual(refs.count, 2)
        for ref in refs {
            let stored = try XCTUnwrap(try cachedFilename(for: ref, db: db))
            XCTAssertTrue(FileManager.default.fileExists(atPath: PDFService.pdfURL(for: stored).path))
            let tags = try db.fetchTags(forReference: ref.id!)
            XCTAssertEqual(tags.map(\.name), ["RL"])
        }
    }

    func testMissingPDFReported() throws {
        let db = try makeDatabase()
        let bibtex = """
        @book{a,
            title = {A},
            file = {PDF:files/1/a.pdf:application/pdf},
        }
        """
        let folder = try makeFakeZoteroFolder(name: "X", bibtex: bibtex, pdfs: [:])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let result = try runImport(folder: folder, db: db, target: nil)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.attached, 0)
        XCTAssertEqual(result.missingPDFs, ["files/1/a.pdf"])
        let refs = try db.fetchAllReferences()
        XCTAssertNil(try cachedFilename(for: try XCTUnwrap(refs.first), db: db))
    }

    func testRejectedAbsolutePathsSurfaceAsMissing() throws {
        let db = try makeDatabase()
        let bibtex = """
        @book{a,
            title = {A},
            file = {PDF:/Users/alice/paper.pdf:application/pdf},
        }
        """
        let folder = try makeFakeZoteroFolder(name: "L", bibtex: bibtex, pdfs: [:])
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let result = try runImport(folder: folder, db: db, target: nil)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.attached, 0)
        XCTAssertEqual(result.missingPDFs, ["/Users/alice/paper.pdf"])
    }

    func testReImportDoesNotDuplicateTag() throws {
        let db = try makeDatabase()
        let bibtex = """
        @article{a,
            title = {Paper A},
            doi = {10.1000/xyz},
            file = {PDF:files/1/a.pdf:application/pdf},
        }
        """
        let folder = try makeFakeZoteroFolder(
            name: "RL",
            bibtex: bibtex,
            pdfs: ["files/1/a.pdf": Data("x".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let tagsProp = try XCTUnwrap(db.findPropertyDefinition(byName: "Tags"))
        let target = ZoteroImportPropertyTarget(propertyId: tagsProp.id!, value: "RL")

        // First import.
        let first = try runImport(folder: folder, db: db, target: target)
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(first.attached, 1)

        // Second import of the same folder — dedup kicks in, PDF copy is skipped.
        let second = try runImport(folder: folder, db: db, target: target)
        XCTAssertEqual(second.imported, 1)
        XCTAssertEqual(second.attached, 0, "Second run should not re-copy the PDF")
        XCTAssertEqual(second.duplicatesSkipped, 1)

        // Exactly one reference, exactly one tag (no duplicate "RL").
        let refs = try db.fetchAllReferences()
        XCTAssertEqual(refs.count, 1)
        let allTags = try db.fetchAllTags()
        XCTAssertEqual(allTags.map(\.name), ["RL"])
    }

    func testStampsCustomMultiSelectProperty() throws {
        let db = try makeDatabase()
        // Seed a user-defined multiSelect property.
        var project = PropertyDefinition(name: "Project", type: .multiSelect, isDefault: false)
        try db.savePropertyDefinition(&project)

        let bibtex = """
        @article{a, title = {X}, doi = {10.1/a}, file = {PDF:files/1/a.pdf:application/pdf}}
        @article{b, title = {Y}, doi = {10.1/b}, file = {PDF:files/2/b.pdf:application/pdf}}
        """
        let folder = try makeFakeZoteroFolder(
            name: "F",
            bibtex: bibtex,
            pdfs: [
                "files/1/a.pdf": Data("a".utf8),
                "files/2/b.pdf": Data("b".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let target = ZoteroImportPropertyTarget(propertyId: project.id!, value: "RL Research")
        let result = try runImport(folder: folder, db: db, target: target)
        XCTAssertEqual(result.imported, 2)

        // Both references have the custom property populated.
        let refs = try db.fetchAllReferences()
        for ref in refs {
            let values = try db.fetchPropertyValues(forReference: ref.id!)
            let match = try XCTUnwrap(values.first { $0.propertyId == project.id! })
            let decoded = try XCTUnwrap(
                (match.value?.data(using: .utf8)).flatMap {
                    try? JSONDecoder().decode([String].self, from: $0)
                }
            )
            XCTAssertEqual(decoded, ["RL Research"])
        }

        // The property's options list now includes the new value (auto-added).
        let reloaded = try XCTUnwrap(db.findPropertyDefinition(byName: "Project"))
        XCTAssertTrue(reloaded.options.contains { $0.value == "RL Research" })
    }

    func testMissingPropertyThrows() throws {
        let db = try makeDatabase()
        let folder = try makeFakeZoteroFolder(
            name: "F",
            bibtex: "@article{a, title = {X}, file = {PDF:files/1/a.pdf:application/pdf}}",
            pdfs: ["files/1/a.pdf": Data("a".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let badTarget = ZoteroImportPropertyTarget(propertyId: 999_999, value: "RL")
        XCTAssertThrowsError(try runImport(folder: folder, db: db, target: badTarget)) { error in
            guard case ZoteroImportError.propertyNotFound = error else {
                XCTFail("Expected propertyNotFound, got \(error)"); return
            }
        }
    }

    func testUnsupportedPropertyTypeLeavesNoOrphanPDFs() throws {
        let db = try makeDatabase()
        // The seeded `Year` property is `number` — not a valid stamping target.
        let yearProp = try XCTUnwrap(db.findPropertyDefinition(byName: "Year"))

        let folder = try makeFakeZoteroFolder(
            name: "F",
            bibtex: "@article{a, title = {X}, file = {PDF:files/1/a.pdf:application/pdf}}",
            pdfs: ["files/1/a.pdf": Data("a".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        // Snapshot the PDF store so we can assert nothing new lingers after the throw.
        let storeURL = AppDatabase.pdfStorageURL
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: storeURL.path)) ?? [])

        let badTarget = ZoteroImportPropertyTarget(propertyId: yearProp.id!, value: "RL")
        XCTAssertThrowsError(
            try ZoteroFolderImporter.importFolder(at: folder, db: db, propertyTarget: badTarget)
        ) { error in
            guard case ZoteroImportError.unsupportedPropertyType = error else {
                XCTFail("Expected unsupportedPropertyType, got \(error)"); return
            }
        }

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: storeURL.path)) ?? [])
        XCTAssertEqual(
            after.subtracting(before), [],
            "No new PDFs should be left in the store after a failed import"
        )
        XCTAssertEqual(try db.fetchAllReferences().count, 0)
    }

    func testPDFAttachedToExistingStubWithoutPDF() throws {
        let db = try makeDatabase()
        // Seed a stub reference with a DOI but no PDF.
        var stub = Reference(title: "Stub"); stub.doi = "10.1/stub"
        try db.saveReference(&stub)
        let stubId = try XCTUnwrap(stub.id)
        XCTAssertNil(try db.pdfFilename(for: stubId))

        let bibtex = """
        @article{a, title = {Full Paper}, doi = {10.1/stub},
            file = {PDF:files/1/a.pdf:application/pdf}}
        """
        let folder = try makeFakeZoteroFolder(
            name: "Stub",
            bibtex: bibtex,
            pdfs: ["files/1/a.pdf": Data("pdf-bytes".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let result = try runImport(folder: folder, db: db, target: nil)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.attached, 1, "PDF should be copied to backfill the attachment-less stub")
        XCTAssertEqual(result.duplicatesSkipped, 1, "Still a duplicate — merged, not inserted")

        // The stub now has a pdfCache row, and the file actually exists.
        let merged = try XCTUnwrap(db.fetchReferences(ids: [stubId]).first)
        let stored = try XCTUnwrap(try cachedFilename(for: merged, db: db))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PDFService.pdfURL(for: stored).path))
        XCTAssertEqual(try db.fetchAllReferences().count, 1)
    }

    func testExistingPDFNotOverwrittenAndNoOrphan() throws {
        let db = try makeDatabase()
        // Seed a reference that already has its own PDF attached (post-B8:
        // attached via pdfCache row, not Reference.pdfPath).
        let priorSource = try makeFakeSourcePDF(name: "prior.pdf", data: Data("prior".utf8))
        let prior = try PDFService.importPDF(from: priorSource)
        copiedPDFPaths.append(prior)
        var existing = Reference(title: "Existing")
        existing.doi = "10.1/already"
        try db.saveReference(&existing)
        let existingId = try XCTUnwrap(existing.id)
        try db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO pdfCache(referenceId, localFilename, contentHash, assetVersion, materializedAt, lastOpenedAt)
                VALUES(?, ?, 'h', 1, ?, ?)
            """, arguments: [existingId, prior, Date(), Date()])
        }

        let storeURL = AppDatabase.pdfStorageURL
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: storeURL.path)) ?? [])

        let bibtex = """
        @article{a, title = {Same Paper}, doi = {10.1/already},
            file = {PDF:files/1/a.pdf:application/pdf}}
        """
        let folder = try makeFakeZoteroFolder(
            name: "Keep",
            bibtex: bibtex,
            pdfs: ["files/1/a.pdf": Data("incoming".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let result = try runImport(folder: folder, db: db, target: nil)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.attached, 0, "Should not copy when existing row already has a PDF")
        XCTAssertEqual(result.duplicatesSkipped, 1)

        let merged = try XCTUnwrap(db.fetchReferences(ids: [existingId]).first)
        XCTAssertEqual(try cachedFilename(for: merged, db: db), prior,
                       "Existing PDF must be preserved, not overwritten")

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: storeURL.path)) ?? [])
        XCTAssertEqual(after.subtracting(before), [], "No new PDFs should appear in the store")
    }

    func testIntraBatchDuplicateCopiesOnlyOnce() throws {
        let db = try makeDatabase()
        // Two entries in the same .bib sharing a DOI — classic "exported overlapping
        // collections" shape. Neither exists in the library yet.
        let bibtex = """
        @article{a, title = {Paper}, doi = {10.1/dup},
            file = {PDF:files/1/a.pdf:application/pdf}}
        @article{b, title = {Paper Again}, doi = {10.1/dup},
            file = {PDF:files/2/b.pdf:application/pdf}}
        """
        let folder = try makeFakeZoteroFolder(
            name: "IntraDup",
            bibtex: bibtex,
            pdfs: [
                "files/1/a.pdf": Data("first".utf8),
                "files/2/b.pdf": Data("second".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let storeURL = AppDatabase.pdfStorageURL
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: storeURL.path)) ?? [])

        let result = try runImport(folder: folder, db: db, target: nil)

        XCTAssertEqual(result.imported, 2, "Both entries are processed — second merges into first")
        XCTAssertEqual(result.attached, 1, "Only one PDF should be copied; second is intra-batch dup")
        XCTAssertEqual(result.duplicatesSkipped, 1)

        // Exactly one row, pointing at the first PDF.
        let refs = try db.fetchAllReferences()
        XCTAssertEqual(refs.count, 1)
        let stored = try XCTUnwrap(try cachedFilename(for: try XCTUnwrap(refs.first), db: db))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PDFService.pdfURL(for: stored).path))

        // No orphans.
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: storeURL.path)) ?? [])
        XCTAssertEqual(after.subtracting(before).count, 1, "Exactly one new PDF, none orphaned")
    }

    func testBatchedDedupAcrossManyEntries() throws {
        let db = try makeDatabase()
        // Seed three existing references — one matches incoming by DOI, one by ISBN,
        // one by URL. A fourth incoming entry has no overlap.
        var seed1 = Reference(title: "Old A"); seed1.doi = "10.1/a"
        var seed2 = Reference(title: "Old B"); seed2.isbn = "978-0262039246"
        var seed3 = Reference(title: "Old C"); seed3.url = "https://example.com/c"
        try db.saveReference(&seed1); try db.saveReference(&seed2); try db.saveReference(&seed3)

        // Incoming: 3 duplicates (by DOI / ISBN / URL) + 1 fresh.
        let bibtex = """
        @article{a, title = {New A}, doi = {10.1/a},
            file = {PDF:files/1/a.pdf:application/pdf}}
        @book{b, title = {New B}, isbn = {978-0-262-03924-6},
            file = {PDF:files/2/b.pdf:application/pdf}}
        @misc{c, title = {New C}, url = {https://example.com/c},
            file = {PDF:files/3/c.pdf:application/pdf}}
        @article{d, title = {Fresh D}, doi = {10.1/d},
            file = {PDF:files/4/d.pdf:application/pdf}}
        """
        let folder = try makeFakeZoteroFolder(
            name: "Batch",
            bibtex: bibtex,
            pdfs: [
                "files/1/a.pdf": Data("a".utf8),
                "files/2/b.pdf": Data("b".utf8),
                "files/3/c.pdf": Data("c".utf8),
                "files/4/d.pdf": Data("d".utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let tagsProp = try XCTUnwrap(db.findPropertyDefinition(byName: "Tags"))
        let target = ZoteroImportPropertyTarget(propertyId: tagsProp.id!, value: "Batch")
        let result = try runImport(folder: folder, db: db, target: target)

        XCTAssertEqual(result.imported, 4)
        XCTAssertEqual(result.duplicatesSkipped, 3, "3 of 4 entries should be detected as duplicates")
        XCTAssertEqual(result.attached, 4,
                       "All 4 PDFs should be copied — the 3 seeds lack a pdfCache row, so the merge backfills them")

        // Library still has 4 distinct refs (3 merged into existing, 1 new).
        XCTAssertEqual(try db.fetchAllReferences().count, 4)
        for ref in try db.fetchAllReferences() {
            XCTAssertNotNil(try cachedFilename(for: ref, db: db),
                            "Every row should now carry a cached PDF filename")
        }
        // All 4 carry the "Batch" tag.
        let allTags = try db.fetchAllTags()
        XCTAssertEqual(allTags.filter { $0.name == "Batch" }.count, 1)
        for ref in try db.fetchAllReferences() {
            let tags = try db.fetchTags(forReference: ref.id!)
            XCTAssertTrue(tags.contains(where: { $0.name == "Batch" }),
                          "Every reference should carry the Batch tag")
        }
    }

    func testBibFileNotFoundThrows() throws {
        let db = try makeDatabase()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RubienZoteroImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        XCTAssertThrowsError(
            try ZoteroFolderImporter.importFolder(at: tempRoot, db: db, propertyTarget: nil)
        ) { error in
            guard case ZoteroFolderImporter.Error.bibFileNotFound = error else {
                XCTFail("Expected bibFileNotFound, got \(error)"); return
            }
        }
    }
}
