#if os(macOS)
import CoreFoundation
import Foundation
import GRDB
import RubienCore

/// The validated `addPaperSource` bridge payload from an external document card.
/// Every ID is only a suggestion hint: the resolver re-checks it against the
/// database, and the user confirms in the chooser sheet before anything is attached.
struct ChatPaperAddRequest: Equatable, Sendable {
    static let maximumSiblingCount = 10

    let url: String
    let title: String
    let parentReferenceId: Int64?
    let siblingReferenceIds: [Int64]

    init(
        url: String,
        title: String = "",
        parentReferenceId: Int64? = nil,
        siblingReferenceIds: [Int64] = []
    ) {
        self.url = url
        self.title = title
        self.parentReferenceId = parentReferenceId
        self.siblingReferenceIds = siblingReferenceIds
    }

    /// Validate a JS message body. The URL must pass `ChatExternalLink`; the
    /// optional hints are dropped (not the request) when malformed.
    init?(messageBody body: Any?) {
        guard let dict = body as? [String: Any],
              let url = dict["url"] as? String,
              ChatExternalLink.classify(url) != .reject
        else { return nil }
        let rawTitle = (dict["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var siblings: [Int64] = []
        if let rawSiblings = dict["siblingReferenceIds"] as? [Any] {
            for raw in rawSiblings.prefix(Self.maximumSiblingCount) {
                if let id = Self.referenceID(raw), !siblings.contains(id) {
                    siblings.append(id)
                }
            }
        }
        self.init(
            url: url,
            title: String(rawTitle.prefix(ChatPaperPresentation.maximumTitleLength)),
            parentReferenceId: Self.referenceID(dict["parentReferenceId"]),
            siblingReferenceIds: siblings)
    }

    /// The same numeric gate as `openPaperReference`: a JSON number (never a
    /// CFBoolean), integral, positive, and exactly representable in JavaScript.
    static func referenceID(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue > 0,
              number.doubleValue <= Double(ChatPaper.maximumSafeReferenceID)
        else { return nil }
        return number.int64Value
    }
}

/// Where a card's **Add to Rubien…** click goes.
enum ChatPaperAddRoute: Equatable {
    /// An attachable PDF/Markdown file: show the attach-or-add chooser sheet.
    case chooser
    /// Paper and web candidates keep today's Add Reference flow, unchanged.
    case addReference(String)

    static func route(_ request: ChatPaperAddRequest) -> ChatPaperAddRoute {
        switch AddReferenceInputRouter.classify(request.url, probe: { _ in
            ImportRouter.PathProbe(exists: false, isDirectory: false)
        }) {
        case .file: return .chooser
        case .metadata, .website, .invalid: return .addReference(request.url)
        }
    }
}

/// Ranks the library references an external file card could be attached to.
/// Pure: all database access goes through the injected `Lookup`.
enum ChatPaperAttachTarget {
    static let maximumSuggestions = 3
    static let minimumShortTitleLength = 3

    enum Reason: Equatable, Sendable {
        case assistant
        case currentPaper
        case shownAbove

        var label: String {
            switch self {
            case .assistant: return "Suggested by the Assistant"
            case .currentPaper: return "Current paper"
            case .shownAbove: return "Shown above"
            }
        }
    }

    struct Suggestion: Equatable, Sendable, Identifiable {
        let referenceId: Int64
        /// The database title, never agent-supplied text.
        let title: String
        let reason: Reason

        var id: Int64 { referenceId }
    }

    struct Resolution: Equatable, Sendable {
        let suggestions: [Suggestion]
        let looksSupplementary: Bool

        /// The default row: the top suggestion only when the agent declared it
        /// or the file looks supplementary; otherwise "Add as a new reference".
        var preselected: Suggestion? {
            guard let top = suggestions.first,
                  top.reason == .assistant || looksSupplementary
            else { return nil }
            return top
        }
    }

    struct Lookup {
        /// Database titles of the given references that still exist.
        var titles: ([Int64]) throws -> [Int64: String]
        /// The parent reference of an active attachment, nil when missing.
        var attachmentParent: (String) throws -> Int64?
    }

    static func resolve(
        request: ChatPaperAddRequest,
        context: AssistantConversationContext,
        lookup: Lookup
    ) -> Resolution {
        let looksSupplementary = URL(string: request.url).map {
            SupplementaryMaterialURL.looksSupplementary(
                url: $0,
                title: request.title.isEmpty ? nil : request.title)
        } ?? false

        let currentID: Int64?
        switch context {
        case .reference(let reference):
            currentID = reference.id
        case .attachment(let attachment):
            currentID = (try? lookup.attachmentParent(attachment.syncId)) ?? nil
        case .library, .unclassifiedResume:
            currentID = nil
        }

        var ids: [Int64] = []
        if let parent = request.parentReferenceId { ids.append(parent) }
        if let currentID { ids.append(currentID) }
        if looksSupplementary { ids.append(contentsOf: request.siblingReferenceIds) }
        let titles = ids.isEmpty ? [:] : ((try? lookup.titles(ids)) ?? [:])

        var ranked: [Suggestion] = []
        if let parent = request.parentReferenceId, let title = titles[parent] {
            ranked.append(Suggestion(referenceId: parent, title: title, reason: .assistant))
        }
        // Always listed (the `@` search excludes the current paper, so it must
        // stay reachable), but preselected only when the file looks supplementary.
        if let currentID, let title = titles[currentID] {
            ranked.append(Suggestion(referenceId: currentID, title: title, reason: .currentPaper))
        }
        if looksSupplementary {
            for sibling in request.siblingReferenceIds {
                guard let title = titles[sibling],
                      let short = shortTitle(title),
                      contains(request.title, short)
                else { continue }
                ranked.append(Suggestion(referenceId: sibling, title: title, reason: .shownAbove))
            }
        }

        var seen = Set<Int64>()
        let suggestions = ranked
            .filter { seen.insert($0.referenceId).inserted }
            .prefix(maximumSuggestions)
        return Resolution(suggestions: Array(suggestions), looksSupplementary: looksSupplementary)
    }

    /// Text before the first `:` or spaced dash (`—`, `–`, `-`), trimmed; nil
    /// when shorter than three characters.
    static func shortTitle(_ title: String) -> String? {
        let separators = [":", " — ", " – ", " - "]
        let cut = separators
            .compactMap { title.range(of: $0)?.lowerBound }
            .min() ?? title.endIndex
        let short = title[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        return short.count >= minimumShortTitleLength ? short : nil
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

extension ChatPaperAttachTarget.Lookup {
    /// Production lookup over the live library database. Call off the main actor.
    static func live(database: AppDatabase) -> Self {
        Self(
            titles: { ids in
                let references = try database.fetchReferences(ids: ids)
                return Dictionary(
                    references.compactMap { reference in reference.id.map { ($0, reference.title) } },
                    uniquingKeysWith: { first, _ in first })
            },
            attachmentParent: { syncId in
                try database.dbWriter.read { db in
                    try Int64.fetchOne(db, sql: """
                        SELECT referenceId FROM referenceAttachment
                        WHERE syncId = ? AND deletedAt IS NULL
                        """, arguments: [syncId])
                }
            })
    }
}
#endif
