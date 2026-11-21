#if os(macOS)
import Foundation
import RubienCore

/// Where a ⌘F search looks: the list it was opened over, or the whole library.
enum LibrarySearchScopeChoice: Hashable, Sendable {
    case thisView
    case library

    /// Whether a result found in this scope can be revealed without leaving
    /// `list`, the library list ⌘F was opened over (`nil` from Home). A "This
    /// view" result already passed the list's scope and filters, and a list
    /// that hides nothing shows every result.
    func revealsInPlace(over list: LibrarySearchViewScope?) -> Bool {
        guard let list else { return false }
        return self == .thisView || !list.hidesReferences
    }
}

/// The library list ⌘F was opened over: its database scope plus the
/// client-side `ViewFilter`s the table applies on top, with the lookup maps
/// those filters resolve against.
struct LibrarySearchViewScope: Equatable, Sendable {
    let name: String
    let icon: String
    let referenceScope: ReferenceScope
    let filters: [ViewFilter]
    let tagMap: [Int64: [Tag]]
    let propertyValueMap: [Int64: [Int64: String]]
    let propertyDefs: [PropertyDefinition]

    /// Whether the list hides any reference. When it doesn't, searching it is
    /// searching the library, and every result is visible in it.
    var hidesReferences: Bool {
        if case .all = referenceScope { return !filters.isEmpty }
        return true
    }
}

/// Runs a ⌘F query against the library (`viewScope == nil`), or against a
/// view's scope and filters. View filters are evaluated by `FilterEngine` after
/// the database fetch, so a positive `limit` (the "Recent references" cap) is
/// applied after filtering.
func librarySearchReferences(
    db: AppDatabase,
    viewScope: LibrarySearchViewScope?,
    filter: ReferenceFilter,
    limit: Int
) throws -> [Reference] {
    guard let viewScope, !viewScope.filters.isEmpty else {
        return try db.fetchReferences(
            scope: viewScope?.referenceScope ?? .all, filter: filter, limit: limit, orderBy: .relevance
        )
    }
    // Unlimited, so read only the columns the table reads too.
    let candidates = try db.fetchReferences(
        scope: viewScope.referenceScope, filter: filter, limit: 0, orderBy: .relevance, lightColumns: true
    )
    try Task.checkCancellation()
    let context = PipelineContext.library(
        db: db,
        tagMap: viewScope.tagMap,
        propertyValueMap: viewScope.propertyValueMap,
        propertyDefs: viewScope.propertyDefs
    )
    let narrowed = FilterEngine.apply(candidates, filters: viewScope.filters, context: context)
    return limit > 0 ? Array(narrowed.prefix(limit)) : narrowed
}
#endif
