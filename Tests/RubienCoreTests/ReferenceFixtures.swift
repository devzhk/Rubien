import Foundation
@testable import RubienCore

enum ReferenceFixtures {
    static func makeRef(
        id: Int64,
        title: String = "Untitled",
        authors: [AuthorName] = [],
        year: Int? = nil,
        journal: String? = nil,
        readingStatus: ReadingStatus = .unread,
        referenceType: ReferenceType = .journalArticle,
        dateAdded: Date = Date()
    ) -> Reference {
        Reference(
            id: id, title: title, authors: authors, year: year, journal: journal,
            dateAdded: dateAdded,
            referenceType: referenceType, readingStatus: readingStatus
        )
    }
}
