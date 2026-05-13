import Foundation
@testable import RubienCore

enum ReferenceFixtures {
    static func makeRef(
        id: Int64,
        title: String = "Untitled",
        authors: [AuthorName] = [],
        year: Int? = nil,
        journal: String? = nil,
        readingStatus: String = ReadingStatus.unread,
        referenceType: ReferenceType = .journalArticle,
        dateAdded: Date = Date(),
        lastReadAt: Date? = nil,
        readCount: Int = 0
    ) -> Reference {
        Reference(
            id: id, title: title, authors: authors, year: year, journal: journal,
            dateAdded: dateAdded,
            referenceType: referenceType, readingStatus: readingStatus,
            lastReadAt: lastReadAt, readCount: readCount
        )
    }
}
