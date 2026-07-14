#if canImport(PDFKit)
import XCTest
import GRDB
@testable import RubienCore
@testable import RubienPDFKit

final class ZoteroLocalAPIClientTests: XCTestCase {
    private let baseURL = URL(string: "http://zotero.test/api/")!

    func testAccessDisabledIsDistinguishedFromNotRunning() async {
        let disabled = ZoteroLocalAPIClient(baseURL: baseURL) { _ in
            ZoteroLocalAPIClient.Response(
                data: Data("Local API is not enabled".utf8),
                statusCode: 403
            )
        }
        do {
            try await disabled.probe()
            XCTFail("Expected accessDisabled")
        } catch {
            XCTAssertEqual(error as? ZoteroLocalAPIError, .accessDisabled)
        }

        let unavailable = ZoteroLocalAPIClient(baseURL: baseURL) { _ in
            throw URLError(.cannotConnectToHost)
        }
        do {
            try await unavailable.probe()
            XCTFail("Expected notRunning")
        } catch {
            XCTAssertEqual(error as? ZoteroLocalAPIError, .notRunning)
        }

        let timedOut = ZoteroLocalAPIClient(baseURL: baseURL) { _ in
            throw URLError(.timedOut)
        }
        do {
            try await timedOut.probe()
            XCTFail("Expected timedOut")
        } catch {
            XCTAssertEqual(error as? ZoteroLocalAPIError, .timedOut)
        }
    }

    func testProbeRejectsUnsupportedAdvertisedVersion() async {
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { _ in
            ZoteroLocalAPIClient.Response(
                data: Data(),
                statusCode: 200,
                headers: ["Zotero-API-Version": "4"]
            )
        }

        do {
            try await client.probe()
            XCTFail("Expected unsupportedAPIVersion")
        } catch {
            XCTAssertEqual(error as? ZoteroLocalAPIError, .unsupportedAPIVersion("4"))
        }
    }

    func testFetchCollectionsDecodesRootAndChildMetadata() async throws {
        let collectionsJSON = try jsonData([
            [
                "key": "ROOT0001",
                "data": ["name": "Research", "parentCollection": false],
                "meta": ["numItems": 3, "numCollections": 1],
            ],
            [
                "key": "CHILD001",
                "data": ["name": "Papers", "parentCollection": "ROOT0001"],
                "meta": ["numItems": 2, "numCollections": 0],
            ],
        ])
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            let data = request.url?.path == "/api/users/0/collections"
                ? collectionsJSON
                : Data()
            return Self.success(data)
        }

        let collections = try await client.fetchCollections()

        XCTAssertEqual(
            collections,
            [
                ZoteroLibraryCollection(
                    key: "ROOT0001",
                    name: "Research",
                    parentKey: nil,
                    itemCount: 3,
                    childCollectionCount: 1
                ),
                ZoteroLibraryCollection(
                    key: "CHILD001",
                    name: "Papers",
                    parentKey: "ROOT0001",
                    itemCount: 2,
                    childCollectionCount: 0
                ),
            ]
        )
    }

    func testFetchCollectionItemsSummarizesPapersAndPDFAttachments() async throws {
        let response = try jsonData([
            [
                "key": "PAPER002",
                "data": [
                    "itemType": "journalArticle",
                    "title": "Beta Paper",
                ],
            ],
            [
                "key": "PDF00002",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "PAPER002",
                    "contentType": "application/pdf",
                    "filename": "beta-paper.pdf",
                ],
            ],
            [
                "key": "SNAP0002",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "PAPER002",
                    "contentType": "text/html",
                    "filename": "snapshot.html",
                ],
            ],
            [
                "key": "NOTE0002",
                "data": [
                    "itemType": "note",
                    "parentItem": "PAPER002",
                ],
            ],
            [
                "key": "PAPER001",
                "data": [
                    "itemType": "conferencePaper",
                    "title": "Alpha Paper",
                ],
            ],
            [
                "key": "PDF00001",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "PAPER001",
                    "contentType": "application/pdf",
                    "title": "Author manuscript",
                ],
            ],
        ])
        let log = ZoteroRequestLog()
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            if let url = request.url { await log.record(url) }
            return Self.success(response)
        }

        let items = try await client.fetchCollectionItems(collectionKey: "COLLECT1")

        XCTAssertEqual(items.map(\.key), ["PAPER001", "PAPER002"])
        XCTAssertEqual(items.map(\.title), ["Alpha Paper", "Beta Paper"])
        XCTAssertEqual(items[0].pdfFilenames, ["Author manuscript"])
        XCTAssertEqual(items[1].pdfFilenames, ["beta-paper.pdf"])
        let requests = await log.snapshot()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "/api/users/0/collections/COLLECT1/items")
        XCTAssertTrue(
            URLComponents(url: request, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "include" && $0.value == "data" } == true
        )
        XCTAssertTrue(
            URLComponents(url: request, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "itemType" && $0.value == "-annotation" }
                == true
        )
        XCTAssertTrue(
            URLComponents(url: request, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "limit" && $0.value == "500" } == true
        )
        XCTAssertTrue(
            URLComponents(url: request, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "sort" && $0.value == "title" } == true
        )
        XCTAssertTrue(
            URLComponents(url: request, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "direction" && $0.value == "asc" } == true
        )
    }

    func testFetchCollectionItemsCapsDisclosurePreview() async throws {
        let response = try jsonData((0 ..< 205).map { index in
            [
                "key": String(format: "PAPER%03d", index),
                "data": [
                    "itemType": "journalArticle",
                    "title": String(format: "Paper %03d", index),
                ],
            ]
        })
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { _ in
            Self.success(response)
        }

        let items = try await client.fetchCollectionItems(collectionKey: "COLLECT1")

        XCTAssertEqual(items.count, 200)
        XCTAssertEqual(items.first?.title, "Paper 000")
        XCTAssertEqual(items.last?.title, "Paper 199")
    }

    func testWholeLibraryExcludesAnnotationsWhenAnnotationImportIsDisabled() async throws {
        let log = ZoteroRequestLog()
        let response = try jsonData([
            [
                "key": "ITEM0001",
                "data": ["itemType": "journalArticle", "title": "Library Paper"],
                "bibtex": "@article{library, title={Library Paper}}",
            ],
        ])
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            if let url = request.url { await log.record(url) }
            return Self.success(response)
        }
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .entireLibrary,
            collections: [],
            includeSubcollections: true,
            includeAnnotations: false,
            db: database,
            propertyTarget: nil
        )

        XCTAssertEqual(plan.entries.count, 1)
        let requests = await log.snapshot()
        XCTAssertEqual(requests.count, 1)
        let queryItems = URLComponents(
            url: try XCTUnwrap(requests.first),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertTrue(queryItems?.contains {
            $0.name == "itemType" && $0.value == "-annotation"
        } == true)
    }

    func testWholeLibraryImportConsumesEveryReportedPage() async throws {
        let firstPage = try jsonData([
            [
                "key": "ITEM0001",
                "data": ["itemType": "journalArticle", "title": "First Paper"],
                "bibtex": "@article{first, title={First Paper}}",
            ],
        ])
        let secondPage = try jsonData([
            [
                "key": "ITEM0002",
                "data": ["itemType": "journalArticle", "title": "Second Paper"],
                "bibtex": "@article{second, title={Second Paper}}",
            ],
        ])
        let log = ZoteroRequestLog()
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            let url = try XCTUnwrap(request.url)
            await log.record(url)
            let start = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "start" })?
                .value
            return ZoteroLocalAPIClient.Response(
                data: start == "0" ? firstPage : secondPage,
                statusCode: 200,
                headers: [
                    "Zotero-API-Version": "3",
                    "Total-Results": "2",
                ]
            )
        }
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .entireLibrary,
            collections: [],
            includeSubcollections: true,
            includeAnnotations: false,
            db: database,
            propertyTarget: nil
        )

        XCTAssertEqual(
            plan.entries.map(\.reference.title),
            ["First Paper", "Second Paper"]
        )
        let requests = await log.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.compactMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "start" })?
                    .value
            },
            ["0", "1"]
        )
        XCTAssertTrue(requests.allSatisfy {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains { $0.name == "limit" && $0.value == "200" } == true
        })
    }

    func testManySelectedCollectionsUseOneFilteredLibrarySnapshot() async throws {
        let collections = (0 ..< 12).map { index in
            ZoteroLibraryCollection(
                key: "COLL\(index)",
                name: "Collection \(index)",
                parentKey: nil,
                itemCount: 10,
                childCollectionCount: 0
            )
        }
        let response = try jsonData([
            [
                "key": "SELECTED",
                "data": [
                    "itemType": "journalArticle",
                    "title": "Selected Paper",
                    "collections": ["COLL0"],
                ],
                "bibtex": "@article{selected, title={Selected Paper}}",
            ],
            [
                "key": "UNFILED1",
                "data": [
                    "itemType": "journalArticle",
                    "title": "Unfiled Paper",
                    "collections": [],
                ],
                "bibtex": "@article{unfiled, title={Unfiled Paper}}",
            ],
            [
                "key": "OUTSIDE1",
                "data": [
                    "itemType": "journalArticle",
                    "title": "Outside Paper",
                    "collections": ["NOTSELECTED"],
                ],
                "bibtex": "@article{outside, title={Outside Paper}}",
            ],
        ])
        let log = ZoteroRequestLog()
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            if let url = request.url { await log.record(url) }
            return Self.success(response)
        }
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections(Set(collections.map(\.key))),
            collections: collections,
            includeSubcollections: false,
            includeAnnotations: false,
            db: database,
            propertyTarget: nil
        )

        XCTAssertEqual(plan.entries.map(\.reference.title), ["Selected Paper"])
        let requests = await log.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.path, "/api/users/0/items")
    }

    func testManyMostlyEmptyCollectionsAvoidFullLibrarySnapshot() async throws {
        let collections = (0 ..< 12).map { index in
            ZoteroLibraryCollection(
                key: "EMPTY\(index)",
                name: "Empty \(index)",
                parentKey: nil,
                itemCount: 1,
                childCollectionCount: 0
            )
        }
        let log = ZoteroRequestLog()
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            if let url = request.url { await log.record(url) }
            return Self.success(Data("[]".utf8))
        }
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections(Set(collections.map(\.key))),
            collections: collections,
            includeSubcollections: false,
            includeAnnotations: false,
            db: database,
            propertyTarget: nil
        )

        XCTAssertTrue(plan.entries.isEmpty)
        let requests = await log.snapshot()
        XCTAssertEqual(requests.count, collections.count)
        XCTAssertFalse(requests.contains { $0.path == "/api/users/0/items" })
    }

    func testCollectionTreeOrdersPathsAndExpandsDescendants() {
        let collections = [
            ZoteroLibraryCollection(
                key: "CHILD001",
                name: "Papers",
                parentKey: "ROOT0001",
                itemCount: 2,
                childCollectionCount: 1
            ),
            ZoteroLibraryCollection(
                key: "ROOT0001",
                name: "Research",
                parentKey: nil,
                itemCount: 3,
                childCollectionCount: 1
            ),
            ZoteroLibraryCollection(
                key: "GRAND001",
                name: "2026",
                parentKey: "CHILD001",
                itemCount: 1,
                childCollectionCount: 0
            ),
        ]

        let rows = ZoteroLibraryCollectionTree.rows(from: collections)
        XCTAssertEqual(rows.map(\.collection.key), ["ROOT0001", "CHILD001", "GRAND001"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(rows.last?.path, "Research / Papers / 2026")
        XCTAssertEqual(
            ZoteroLibraryCollectionTree.expandingDescendants(
                of: ["ROOT0001"],
                in: collections
            ),
            ["ROOT0001", "CHILD001", "GRAND001"]
        )
    }

    func testPrepareDeduplicatesOverlappingCollectionsAndAssociatesLocalPDF() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroLocalAPIClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdfURL)

        let parent: [String: Any] = [
            "key": "ITEM0001",
            "data": [
                "itemType": "journalArticle",
                "title": "Fallback title",
                "dateAdded": "2025-02-03T04:05:06Z",
                "dateModified": "2025-02-04T04:05:06Z",
            ],
            "bibtex": """
            @article{item1, title={Local API Paper}, author={Ada Lovelace}, \
            year={2025}, doi={10.1/example}}
            """,
        ]
        let attachment: [String: Any] = [
            "key": "ATTACH01",
            "data": [
                "itemType": "attachment",
                "parentItem": "ITEM0001",
                "contentType": "application/pdf",
                "filename": "paper.pdf",
            ],
            "links": ["enclosure": ["href": pdfURL.absoluteString]],
        ]
        let firstCollection = try jsonData([parent, attachment])
        let secondCollection = try jsonData([parent])

        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            switch request.url?.path {
            case "/api/users/0/collections/ALPHA001/items":
                return Self.success(firstCollection)
            case "/api/users/0/collections/BETA0001/items":
                return Self.success(secondCollection)
            default:
                return Self.success(Data("[]".utf8))
            }
        }
        let collections = [
            ZoteroLibraryCollection(
                key: "ALPHA001",
                name: "Alpha",
                parentKey: nil,
                itemCount: 1,
                childCollectionCount: 0
            ),
            ZoteroLibraryCollection(
                key: "BETA0001",
                name: "Beta",
                parentKey: nil,
                itemCount: 1,
                childCollectionCount: 0
            ),
        ]
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections(["ALPHA001", "BETA0001"]),
            collections: collections,
            includeSubcollections: false,
            db: database,
            propertyTarget: nil
        )

        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].reference.title, "Local API Paper")
        XCTAssertEqual(plan.entries[0].reference.authors, [AuthorName(given: "Ada", family: "Lovelace")])
        XCTAssertEqual(plan.entries[0].reference.year, 2025)
        XCTAssertEqual(plan.entries[0].reference.doi, "10.1/example")
        XCTAssertNotEqual(
            plan.entries[0].reference.dateAdded,
            ISO8601DateFormatter().date(from: "2025-02-03T04:05:06Z")
        )
        XCTAssertEqual(plan.entries[0].attachmentURLs, [pdfURL])
        XCTAssertEqual(plan.entries[0].attachmentPaths, ["paper.pdf"])
        XCTAssertEqual(plan.entries[0].missingAttachmentPaths, [])
        XCTAssertEqual(plan.sourceName, "Zotero — 2 collections")
        XCTAssertNil(plan.folderURL)
    }

    func testCommitStampsFreshReferenceWithRubienAdditionTime() throws {
        let preparedDate = Date(timeIntervalSince1970: 1_600_000_000)
        var preparedReference = Reference(title: "Commit-Time Paper")
        preparedReference.dateAdded = preparedDate
        preparedReference.dateModified = preparedDate
        let entry = ZoteroFolderImportPlan.Entry(
            sourceIndex: 0,
            reference: preparedReference,
            attachmentURLs: [],
            attachmentPaths: []
        )
        let plan = ZoteroFolderImportPlan(
            folderURL: nil,
            sourceName: "Zotero",
            propertyTarget: nil,
            entries: [entry]
        )
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let commitStartedAt = Date()
        _ = try ZoteroFolderImporter.commit(
            plan: plan,
            selectedEntryIDs: Set(plan.entries.map(\.id)),
            db: database
        )
        let commitFinishedAt = Date()

        let reference = try XCTUnwrap(database.fetchAllReferences().first)
        XCTAssertGreaterThan(reference.dateAdded, preparedDate)
        XCTAssertGreaterThanOrEqual(
            reference.dateAdded,
            commitStartedAt.addingTimeInterval(-1)
        )
        XCTAssertLessThanOrEqual(
            reference.dateAdded,
            commitFinishedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(reference.dateModified, reference.dateAdded)
    }

    func testPrepareResolvesLinkedFileThroughSupportedFileEndpoint() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroLinkedFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("linked.pdf")
        try Data("%PDF-1.4\nlinked\n%%EOF".utf8).write(to: pdfURL)

        let itemResponse = try jsonData([
            [
                "key": "ITEM0001",
                "data": ["itemType": "journalArticle", "title": "Linked Paper"],
                "bibtex": "@article{linked, title={Linked Paper}}",
            ],
            [
                "key": "LINKPDF1",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "ITEM0001",
                    "contentType": "application/pdf",
                    "filename": "linked.pdf",
                ],
            ],
        ])
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            switch request.url?.path {
            case "/api/users/0/collections/LINKED01/items":
                return Self.success(itemResponse)
            case "/api/users/0/items/LINKPDF1/file/view/url":
                return Self.success(Data(pdfURL.absoluteString.utf8))
            default:
                return Self.success(Data("[]".utf8))
            }
        }
        let collection = ZoteroLibraryCollection(
            key: "LINKED01",
            name: "Linked",
            parentKey: nil,
            itemCount: 1,
            childCollectionCount: 0
        )
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections([collection.key]),
            collections: [collection],
            includeSubcollections: false,
            includeAnnotations: false,
            db: database,
            propertyTarget: nil
        )

        XCTAssertEqual(plan.entries.first?.attachmentURLs, [pdfURL])
        XCTAssertEqual(plan.entries.first?.missingAttachmentPaths, [])
    }

    func testLinkedURLPDFIsReportedMissingWithoutBlockingMetadata() async throws {
        let itemResponse = try jsonData([
            [
                "key": "ITEM0001",
                "data": ["itemType": "journalArticle", "title": "Remote PDF"],
                "bibtex": "@article{remote, title={Remote PDF}}",
            ],
            [
                "key": "REMOTEP1",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "ITEM0001",
                    "linkMode": "linked_url",
                    "contentType": "application/pdf",
                    "title": "Publisher PDF",
                ],
            ],
        ])
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            if request.url?.path == "/api/users/0/collections/REMOTE01/items" {
                return Self.success(itemResponse)
            }
            return ZoteroLocalAPIClient.Response(
                data: Data("Not a file attachment".utf8),
                statusCode: 400,
                headers: ["Zotero-API-Version": "3"]
            )
        }
        let collection = ZoteroLibraryCollection(
            key: "REMOTE01",
            name: "Remote",
            parentKey: nil,
            itemCount: 1,
            childCollectionCount: 0
        )
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections([collection.key]),
            collections: [collection],
            includeSubcollections: false,
            includeAnnotations: false,
            db: database,
            propertyTarget: nil
        )

        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].reference.title, "Remote PDF")
        XCTAssertEqual(plan.entries[0].attachmentURLs, [])
        XCTAssertEqual(plan.entries[0].missingAttachmentPaths, ["Publisher PDF"])
    }

    func testAnnotatedPDFAttachmentIsPreferredOverSupplement() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroMultiPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let supplementURL = tempRoot.appendingPathComponent("supplement.pdf")
        let primaryURL = tempRoot.appendingPathComponent("primary.pdf")
        try Data("%PDF-1.4\nsupplement\n%%EOF".utf8).write(to: supplementURL)
        try Data("%PDF-1.4\nprimary\n%%EOF".utf8).write(to: primaryURL)

        let itemResponse = try jsonData([
            [
                "key": "ITEM0001",
                "data": ["itemType": "journalArticle", "title": "Multi PDF"],
                "bibtex": "@article{multi, title={Multi PDF}}",
            ],
            [
                "key": "AAAASUPP",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "ITEM0001",
                    "contentType": "application/pdf",
                    "filename": "supplement.pdf",
                ],
                "links": ["enclosure": ["href": supplementURL.absoluteString]],
            ],
            [
                "key": "ZZZPRIMARY",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "ITEM0001",
                    "contentType": "application/pdf",
                    "filename": "primary.pdf",
                ],
                "links": ["enclosure": ["href": primaryURL.absoluteString]],
            ],
        ])
        let annotationResponse = try jsonData([
            [
                "key": "ANN00001",
                "data": [
                    "itemType": "annotation",
                    "parentItem": "ZZZPRIMARY",
                    "annotationType": "highlight",
                    "annotationText": "Primary text",
                    "annotationPosition": "{\"pageIndex\":0,\"rects\":[[10,20,40,28]]}",
                ],
            ],
        ])
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            switch request.url?.path {
            case "/api/users/0/collections/MULTIPDF/items":
                return Self.success(itemResponse)
            case "/api/users/0/items/ZZZPRIMARY/children":
                return Self.success(annotationResponse)
            default:
                return Self.success(Data("[]".utf8))
            }
        }
        let collection = ZoteroLibraryCollection(
            key: "MULTIPDF",
            name: "Multi PDF",
            parentKey: nil,
            itemCount: 1,
            childCollectionCount: 0
        )
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections([collection.key]),
            collections: [collection],
            includeSubcollections: false,
            includeAnnotations: true,
            db: database,
            propertyTarget: nil
        )

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry.attachmentURLs, [primaryURL])
        XCTAssertEqual(entry.annotations.count, 1)
        XCTAssertEqual(entry.annotations.first?.selectedText, "Primary text")
        XCTAssertEqual(entry.skippedAnnotationCount, 0)
    }

    func testModestCollectionUsesTargetedAnnotationsAndPreservesAttachmentOrder() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroTargetedAnnotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let firstPDFURL = tempRoot.appendingPathComponent("primary.pdf")
        try Data("%PDF-1.4\nprimary\n%%EOF".utf8).write(to: firstPDFURL)

        var items: [[String: Any]] = [[
            "key": "ITEM0001",
            "data": ["itemType": "journalArticle", "title": "Thirteen PDFs"],
            "bibtex": "@article{thirteen, title={Thirteen PDFs}}",
        ]]
        for index in 0 ..< 13 {
            let key = index == 0 ? "ZZZFIRST" : "ATTACH\(index)"
            var attachment: [String: Any] = [
                "key": key,
                "data": [
                    "itemType": "attachment",
                    "parentItem": "ITEM0001",
                    "contentType": "application/pdf",
                    "filename": "paper-\(index).pdf",
                ],
            ]
            if index == 0 {
                attachment["links"] = ["enclosure": ["href": firstPDFURL.absoluteString]]
            }
            items.append(attachment)
        }
        let itemResponse = try jsonData(items)
        let log = ZoteroRequestLog()
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            if let url = request.url { await log.record(url) }
            if request.url?.path == "/api/users/0/collections/MODEST01/items" {
                return Self.success(itemResponse)
            }
            return Self.success(Data("[]".utf8))
        }
        let collection = ZoteroLibraryCollection(
            key: "MODEST01",
            name: "Modest",
            parentKey: nil,
            itemCount: 13,
            childCollectionCount: 0
        )
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections([collection.key]),
            collections: [collection],
            includeSubcollections: false,
            includeAnnotations: true,
            db: database,
            propertyTarget: nil
        )

        XCTAssertEqual(plan.entries.first?.attachmentURLs, [firstPDFURL])
        let requests = await log.snapshot()
        XCTAssertEqual(
            requests.filter { $0.path.hasSuffix("/children") }.count,
            13
        )
        XCTAssertFalse(requests.contains { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "itemType" && $0.value == "annotation"
            } == true
        })
    }

    func testAnnotationsConvertAndRepeatedCommitDoesNotDuplicateThem() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroAnnotationImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pdfURL = tempRoot.appendingPathComponent("annotated.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdfURL)

        let itemResponse = try jsonData([
            [
                "key": "ITEM0001",
                "data": ["itemType": "journalArticle", "title": "Annotated"],
                "bibtex": "@article{annotated, title={Annotated Paper}, doi={10.1/annotated}}",
            ],
            [
                "key": "ATTACH01",
                "data": [
                    "itemType": "attachment",
                    "parentItem": "ITEM0001",
                    "contentType": "application/pdf",
                    "filename": "annotated.pdf",
                ],
                "links": ["enclosure": ["href": pdfURL.absoluteString]],
            ],
        ])
        let position = """
        {"pageIndex":1,"rects":[[10.0,20.0,40.0,28.0],[10.0,30.0,50.0,38.0]]}
        """
        let annotationsResponse = try jsonData([
            [
                "key": "ANN00001",
                "data": [
                    "itemType": "annotation",
                    "parentItem": "ATTACH01",
                    "annotationType": "highlight",
                    "annotationText": "x < y > z",
                    "annotationComment": "Remember & cite",
                    "annotationColor": "#ffec00",
                    "annotationPosition": position,
                    "dateAdded": "2025-02-03T04:05:06Z",
                    "dateModified": "2025-02-04T04:05:06Z",
                ],
            ],
            [
                "key": "ANN00002",
                "data": [
                    "itemType": "annotation",
                    "parentItem": "ATTACH01",
                    "annotationType": "underline",
                    "annotationText": "Underlined claim",
                    "annotationColor": "#2ea8e5",
                    "annotationPosition": position,
                ],
            ],
            [
                "key": "ANN00003",
                "data": [
                    "itemType": "annotation",
                    "parentItem": "ATTACH01",
                    "annotationType": "note",
                    "annotationComment": "Margin note",
                    "annotationColor": "#a28ae5",
                    "annotationPosition": position,
                ],
            ],
            [
                "key": "ANN00004",
                "data": [
                    "itemType": "annotation",
                    "parentItem": "ATTACH01",
                    "annotationType": "ink",
                    "annotationPosition": position,
                ],
            ],
            [
                "key": "ANN00005",
                "data": [
                    "itemType": "annotation",
                    "parentItem": "ATTACH01",
                    "annotationType": "image",
                    "annotationPosition": position,
                ],
            ],
            [
                "key": "ANN00006",
                "data": [
                    "itemType": "annotation",
                    "parentItem": "ATTACH01",
                    "annotationType": "underline",
                    "annotationText": "Missing geometry",
                    "annotationPosition": "{\"pageIndex\":1,\"rects\":[]}",
                ],
            ],
        ])
        let client = ZoteroLocalAPIClient(baseURL: baseURL) { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let isAnnotationRequest = components?.queryItems?.contains {
                $0.name == "itemType" && $0.value == "annotation"
            } == true
            if isAnnotationRequest
                || request.url?.path == "/api/users/0/items/ATTACH01/children" {
                return Self.success(annotationsResponse)
            }
            if request.url?.path == "/api/users/0/collections/ANNOTATE/items" {
                return Self.success(itemResponse)
            }
            return Self.success(Data("[]".utf8))
        }
        let collection = ZoteroLibraryCollection(
            key: "ANNOTATE",
            name: "Annotated",
            parentKey: nil,
            itemCount: 1,
            childCollectionCount: 0
        )
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        let plan = try await ZoteroLibraryImporter.prepare(
            client: client,
            scope: .collections([collection.key]),
            collections: [collection],
            includeSubcollections: true,
            includeAnnotations: true,
            db: database,
            propertyTarget: nil
        )

        let entry = try XCTUnwrap(plan.entries.first)
        XCTAssertEqual(entry.annotations.count, 3)
        XCTAssertEqual(entry.skippedAnnotationCount, 3)
        XCTAssertEqual(entry.annotations[0].type, .highlight)
        XCTAssertEqual(entry.annotations[0].selectedText, "x < y > z")
        XCTAssertEqual(entry.annotations[0].noteText, "Remember & cite")
        XCTAssertEqual(entry.annotations[0].color, "#ffec00")
        XCTAssertEqual(entry.annotations[0].pageIndex, 1)
        XCTAssertEqual(
            entry.annotations[0].rects,
            [
                PDFAnnotationRect(rect: CGRect(x: 10, y: 20, width: 30, height: 8)),
                PDFAnnotationRect(rect: CGRect(x: 10, y: 30, width: 40, height: 8)),
            ]
        )
        XCTAssertEqual(entry.annotations[1].type, .underline)
        XCTAssertEqual(entry.annotations[1].selectedText, "Underlined claim")
        XCTAssertEqual(entry.annotations[1].color, "#2ea8e5")
        XCTAssertEqual(entry.annotations[2].type, .note)
        XCTAssertNil(entry.annotations[2].selectedText)
        XCTAssertEqual(entry.annotations[2].noteText, "Margin note")
        XCTAssertEqual(entry.annotations[2].color, "#a28ae5")

        let first = try ZoteroFolderImporter.commit(
            plan: plan,
            selectedEntryIDs: [entry.id],
            db: database
        )
        XCTAssertEqual(first.annotationsImported, 3)
        XCTAssertEqual(first.annotationsSkipped, 3)
        let reference = try XCTUnwrap(database.fetchAllReferences().first)
        let storedFilename = try XCTUnwrap(try database.pdfFilename(for: XCTUnwrap(reference.id)))
        defer { try? FileManager.default.removeItem(at: PDFService.pdfURL(for: storedFilename)) }
        let referenceID = try XCTUnwrap(reference.id)
        var storedAnnotations = try database.fetchAnnotations(referenceId: referenceID)
        XCTAssertEqual(storedAnnotations.count, 3)
        var locallyRecolored = try XCTUnwrap(storedAnnotations.first { $0.type == .highlight })
        locallyRecolored.color = "#123456"
        try database.saveAnnotation(&locallyRecolored)

        let second = try ZoteroFolderImporter.commit(
            plan: plan,
            selectedEntryIDs: [entry.id],
            db: database
        )
        XCTAssertEqual(second.annotationsImported, 0)
        storedAnnotations = try database.fetchAnnotations(referenceId: referenceID)
        XCTAssertEqual(storedAnnotations.count, 3)
        XCTAssertEqual(storedAnnotations.first { $0.type == .highlight }?.color, "#123456")
    }

    func testDifferentExistingPDFSkipsCoordinateAnnotations() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroDifferentPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let zoteroPDF = tempRoot.appendingPathComponent("zotero.pdf")
        try Data("%PDF-1.4\nzotero-edition\n%%EOF".utf8).write(to: zoteroPDF)

        let existingFilename = "\(UUID().uuidString)_existing.pdf"
        let existingURL = AppDatabase.pdfStorageURL.appendingPathComponent(existingFilename)
        try Data("%PDF-1.4\ndifferent-edition\n%%EOF".utf8).write(to: existingURL)
        defer { try? FileManager.default.removeItem(at: existingURL) }

        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))
        var existing = Reference(title: "Existing Paper")
        existing.doi = "10.1/different-pdf"
        _ = try database.batchImportReferences(
            [existing],
            pdfFilenames: [existingFilename]
        )

        var incoming = Reference(title: "Zotero Paper")
        incoming.doi = existing.doi
        let draft = PDFAnnotationDraft(
            type: .highlight,
            selectedText: "Edition-specific coordinates",
            pageIndex: 0,
            rects: [CGRect(x: 10, y: 20, width: 30, height: 8)]
        )
        let entry = ZoteroFolderImportPlan.Entry(
            sourceIndex: 0,
            reference: incoming,
            attachmentURLs: [zoteroPDF],
            attachmentPaths: ["zotero.pdf"],
            annotations: [draft]
        )
        let plan = ZoteroFolderImportPlan(
            folderURL: nil,
            sourceName: "Zotero — Different edition",
            propertyTarget: nil,
            entries: [entry]
        )

        let result = try ZoteroFolderImporter.commit(
            plan: plan,
            selectedEntryIDs: [entry.id],
            db: database
        )

        XCTAssertEqual(result.attached, 0)
        XCTAssertEqual(result.annotationsImported, 0)
        XCTAssertEqual(result.annotationsSkipped, 1)
        let reference = try XCTUnwrap(database.fetchAllReferences().first)
        XCTAssertEqual(
            try database.fetchAnnotations(referenceId: XCTUnwrap(reference.id)),
            []
        )
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("%PDF-1.4\ndifferent-edition\n%%EOF".utf8))
    }

    func testLaterIntraBatchPDFAnchorsAnnotationsWhenEarlierCopyFails() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoteroIntraBatchAnchorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let missingPDF = tempRoot.appendingPathComponent("missing.pdf")
        let availablePDF = tempRoot.appendingPathComponent("available.pdf")
        let availableData = Data("%PDF-1.4\navailable\n%%EOF".utf8)
        try availableData.write(to: availablePDF)

        var earlier = Reference(title: "Earlier")
        earlier.doi = "10.1/intra-anchor"
        var later = Reference(title: "Later")
        later.doi = earlier.doi
        let draft = PDFAnnotationDraft(
            type: .underline,
            selectedText: "Later attachment",
            pageIndex: 0,
            rects: [CGRect(x: 12, y: 24, width: 36, height: 9)]
        )
        let entries = [
            ZoteroFolderImportPlan.Entry(
                sourceIndex: 0,
                reference: earlier,
                attachmentURLs: [missingPDF],
                attachmentPaths: ["missing.pdf"]
            ),
            ZoteroFolderImportPlan.Entry(
                sourceIndex: 1,
                reference: later,
                attachmentURLs: [availablePDF],
                attachmentPaths: ["available.pdf"],
                annotations: [draft]
            ),
        ]
        let plan = ZoteroFolderImportPlan(
            folderURL: nil,
            sourceName: "Zotero — Intra-batch",
            propertyTarget: nil,
            entries: entries
        )
        let database = try AppDatabase(DatabaseQueue(path: ":memory:"))

        let result = try ZoteroFolderImporter.commit(
            plan: plan,
            selectedEntryIDs: Set(entries.map(\.id)),
            db: database
        )

        XCTAssertEqual(result.attached, 1)
        XCTAssertEqual(result.annotationsImported, 1)
        XCTAssertEqual(result.annotationsSkipped, 0)
        XCTAssertEqual(result.missingPDFs, ["missing.pdf"])
        let reference = try XCTUnwrap(database.fetchAllReferences().first)
        let referenceID = try XCTUnwrap(reference.id)
        XCTAssertEqual(try database.fetchAnnotations(referenceId: referenceID).count, 1)
        let storedFilename = try XCTUnwrap(try database.pdfFilename(for: referenceID))
        defer { try? FileManager.default.removeItem(at: PDFService.pdfURL(for: storedFilename)) }
        XCTAssertEqual(try Data(contentsOf: PDFService.pdfURL(for: storedFilename)), availableData)
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func success(_ data: Data) -> ZoteroLocalAPIClient.Response {
        ZoteroLocalAPIClient.Response(
            data: data,
            statusCode: 200,
            headers: ["Zotero-API-Version": "3"]
        )
    }
}

private actor ZoteroRequestLog {
    private var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }

    func snapshot() -> [URL] {
        urls
    }
}
#endif
