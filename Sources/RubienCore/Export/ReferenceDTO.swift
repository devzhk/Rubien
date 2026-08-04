import Foundation

/// A custom-property value in Rubien's stable CLI/MCP reference JSON shape.
public struct CustomPropertyValueDTO: Encodable, Sendable {
    public let propertyId: Int64
    public let name: String
    public let type: String
    public let value: String

    public init(propertyId: Int64, name: String, type: String, value: String) {
        self.propertyId = propertyId
        self.name = name
        self.type = type
        self.value = value
    }
}

/// Rubien's stable automation-oriented reference JSON shape.
public struct ReferenceDTO: Encodable, Sendable {
    public let id: Int64?
    public let title: String
    public let authors: String
    public let year: Int?
    public let journal: String?
    public let volume: String?
    public let issue: String?
    public let pages: String?
    public let doi: String?
    public let url: String?
    public let siteName: String?
    public let abstract: String?
    public let referenceType: String
    public let dateAdded: Date
    public let dateModified: Date
    public let pdfPath: String?
    public let notes: String?
    public let isbn: String?
    public let issn: String?
    public let publisher: String?
    public let language: String?
    public let edition: String?
    public let readingStatus: String
    public let lastReadAt: Date?
    public let readCount: Int
    public let customProperties: [CustomPropertyValueDTO]

    public init(
        from ref: Reference,
        defs: [PropertyDefinition] = [],
        valuesByRef: [Int64: [Int64: String]] = [:],
        pdfFilenamesByRef: [Int64: String] = [:]
    ) {
        id = ref.id
        title = ref.title
        authors = ref.authors.displayString
        year = ref.year
        journal = ref.journal
        volume = ref.volume
        issue = ref.issue
        pages = ref.pages
        doi = ref.doi
        url = ref.url
        siteName = ref.siteName
        abstract = ref.abstract
        referenceType = ref.referenceType.rawValue
        dateAdded = ref.dateAdded
        dateModified = ref.dateModified
        pdfPath = ref.id.flatMap { pdfFilenamesByRef[$0] }
        notes = ref.notes
        isbn = ref.isbn
        issn = ref.issn
        publisher = ref.publisher
        language = ref.language
        edition = ref.edition
        readingStatus = ref.readingStatus
        lastReadAt = ref.lastReadAt
        readCount = ref.readCount

        let refValues = ref.id.flatMap { valuesByRef[$0] } ?? [:]
        customProperties = defs
            .filter { !$0.isDefault }
            .compactMap { def in
                guard let propertyID = def.id, let value = refValues[propertyID] else {
                    return nil
                }
                return CustomPropertyValueDTO(
                    propertyId: propertyID,
                    name: def.name,
                    type: def.type.rawValue,
                    value: value
                )
            }
    }
}
