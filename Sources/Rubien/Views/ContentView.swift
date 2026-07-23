#if os(macOS)
import SwiftUI
import Combine
import AppKit
import WebKit
import RubienCore
import RubienPDFKit

enum SidebarItem: Hashable {
    case allReferences
    case tag(Int64)
    case titleKeyword(String)
    case view(Int64)
}

struct SearchQuery {
    var keyword: String = ""
    var author: String = ""
    var yearFrom: Int?
    var yearTo: Int?
    var journal: String = ""
    var type: ReferenceType?

    static func parse(_ text: String) -> SearchQuery {
        var q = SearchQuery()
        var keywords: [String] = []
        for part in text.components(separatedBy: " ") {
            if part.hasPrefix("author:") {
                q.author = String(part.dropFirst("author:".count))
            } else if part.hasPrefix("year:") {
                let val = String(part.dropFirst("year:".count))
                if val.contains("-") {
                    let comps = val.split(separator: "-", maxSplits: 1)
                    if val.hasPrefix("-") {
                        q.yearTo = Int(comps.last ?? "")
                    } else if comps.count == 2 {
                        q.yearFrom = Int(comps[0])
                        q.yearTo = Int(comps[1])
                    } else {
                        q.yearFrom = Int(comps[0])
                    }
                } else {
                    q.yearFrom = Int(val)
                    q.yearTo = q.yearFrom
                }
            } else if part.hasPrefix("journal:") {
                q.journal = String(part.dropFirst("journal:".count))
            } else if part.hasPrefix("type:") {
                let val = String(part.dropFirst("type:".count))
                q.type = ReferenceType.allCases.first { $0.rawValue == val }
            } else if !part.isEmpty {
                keywords.append(part)
            }
        }
        q.keyword = keywords.joined(separator: " ")
        return q
    }
}

/// Side-effect-free result of reading and parsing Markdown sources.
struct MarkdownImportPreparationResult: Sendable {
    let entries: [PreparedReferenceImport]
    let sourcesByEntryID: [UUID: MaterializedImportSource]
    let unreadableSources: [MaterializedImportSource]

    var unreadableFilenames: [String] {
        unreadableSources.map { $0.fileURL.lastPathComponent }
    }
}

enum FileImportReviewPresentation {
    static func shouldReview(
        requestedSourceCount: Int,
        preparedItemCount _: Int
    ) -> Bool {
        requestedSourceCount > 1
    }
}

/// Holds a prepared handoff while its initiating sheet animates away. SwiftUI
/// cannot reliably present a second sheet from the same host until the first
/// sheet's `onDismiss` has run.
struct DeferredSheetHandoff<Payload> {
    private var payload: Payload?

    var hasPendingPayload: Bool { payload != nil }

    mutating func stage(_ payload: Payload) {
        self.payload = payload
    }

    mutating func takeAfterDismiss() -> Payload? {
        defer { payload = nil }
        return payload
    }
}

/// Reads and parses Markdown sources without occupying the main actor. This
/// worker never receives a database, so preparation cannot persist anything.
enum MarkdownImportWorker {
    static func prepareSources(
        _ sources: [MaterializedImportSource]
    ) async -> MarkdownImportPreparationResult {
        await Task.detached(priority: .userInitiated) {
            var entries: [PreparedReferenceImport] = []
            var sourcesByEntryID: [UUID: MaterializedImportSource] = [:]
            var unreadableSources: [MaterializedImportSource] = []

            for source in sources {
                let url = source.fileURL
                guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                    unreadableSources.append(source)
                    continue
                }
                let entry = PreparedReferenceImport(
                    reference: MarkdownImporter.parse(
                        content,
                        filename: url.deletingPathExtension().lastPathComponent
                    ),
                    sourceLabel: url.lastPathComponent
                )
                entries.append(entry)
                sourcesByEntryID[entry.id] = source
            }

            return MarkdownImportPreparationResult(
                entries: entries,
                sourcesByEntryID: sourcesByEntryID,
                unreadableSources: unreadableSources
            )
        }.value
    }
}

/// Reads and parses standard reference files without touching the library.
enum StandardReferenceImportWorker {
    static func prepareBibTeX(from url: URL) async throws -> [PreparedReferenceImport] {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let content = try String(contentsOf: url, encoding: .utf8)
            return BibTeXImporter.parse(content).map {
                PreparedReferenceImport(reference: $0, sourceLabel: url.lastPathComponent)
            }
        }.value
    }

    static func prepareRIS(from url: URL) async throws -> [PreparedReferenceImport] {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let content = try String(contentsOf: url, encoding: .utf8)
            return RISImporter.parse(content).map {
                PreparedReferenceImport(reference: $0, sourceLabel: url.lastPathComponent)
            }
        }.value
    }
}

private enum StandardReferenceImportFormat: Sendable {
    case bibTeX
    case ris

    var parsingProgress: String {
        switch self {
        case .bibTeX:
            String(localized: "Parsing BibTeX…", bundle: .module)
        case .ris:
            String(localized: "Parsing RIS…", bundle: .module)
        }
    }

    var reviewTitle: String {
        switch self {
        case .bibTeX:
            String(localized: "Review BibTeX import", bundle: .module)
        case .ris:
            String(localized: "Review RIS import", bundle: .module)
        }
    }

    func prepare(from url: URL) async throws -> [PreparedReferenceImport] {
        switch self {
        case .bibTeX:
            try await StandardReferenceImportWorker.prepareBibTeX(from: url)
        case .ris:
            try await StandardReferenceImportWorker.prepareRIS(from: url)
        }
    }
}

/// The pending metadata rows created by one PDF import batch. Keeping this
/// scope separate from the durable global queue lets a batch open review
/// immediately without mixing in unrelated older work.
enum PendingMetadataReviewScope: Equatable {
    case queuedImport([Int64])

    static func forQueuedIntakeIDs(_ intakeIDs: [Int64]) -> Self? {
        var seen = Set<Int64>()
        let uniqueIDs = intakeIDs.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return nil }
        return .queuedImport(uniqueIDs)
    }
}

enum PendingMetadataIntakePresentation {
    /// A newly-created batch already owns the exact durable intake snapshots
    /// it should review. Prefer those over the asynchronously observed global
    /// queue so the sheet cannot initialize empty and remain stale.
    static func intakesForReview(
        observedPending: [MetadataIntake],
        scopedPending: [MetadataIntake]?
    ) -> [MetadataIntake] {
        scopedPending ?? observedPending
    }

    static func scopedIntakes(from queuedIntakes: [MetadataIntake]) -> [MetadataIntake]? {
        guard let scope = PendingMetadataReviewScope.forQueuedIntakeIDs(
            queuedIntakes.compactMap(\.id)
        ), case let .queuedImport(ids) = scope else {
            return nil
        }
        return ids.compactMap { id in
            queuedIntakes.first { $0.id == id }
        }
    }
}

@MainActor
final class LibraryViewModel: ObservableObject {
    /// The current page of references returned by the database-level query.
    @Published var references: [Reference] = []
    @Published var pendingMetadataIntakes: [MetadataIntake] = []
    @Published var tags: [Tag] = []
    @Published var selectedSidebar: SidebarItem = .allReferences {
        didSet {
            if oldValue != selectedSidebar || !isObservingCurrentReferenceScope {
                rebuildReferenceObserver()
            }
            syncColumnConfigFromView()
        }
    }

    func selectSidebar(
        _ item: SidebarItem,
        stashCurrentDraft: Bool = true,
        preemptsInitialDefaultView: Bool = false
    ) {
        if preemptsInitialDefaultView { hasAppliedDefaultView = true }
        if stashCurrentDraft { stashDraftIfDirty(for: selectedSidebar) }

        // Home is a separate destination, so returning to the already-selected
        // library row is the common path. Do not reassign the @Published value:
        // even an equal assignment emits objectWillChange and invalidates the
        // whole ContentView hierarchy. Still reconcile the observer/config in
        // case a synced saved view changed while Home was visible.
        if selectedSidebar == item {
            if !isObservingCurrentReferenceScope { rebuildReferenceObserver() }
            syncColumnConfigFromView()
            return
        }
        selectedSidebar = item
    }

    func stashCurrentViewDraft() {
        stashDraftIfDirty(for: selectedSidebar)
    }
    /// Raw search text typed by the user; debounced before hitting the DB.
    @Published var searchText = "" {
        didSet { scheduleSearchDebounce() }
    }
    @Published var isImporting = false
    @Published var importProgress: String?
    /// Transient confirmation for single-reference adds — kept SEPARATE from
    /// `importProgress` so a quick "Added"/"Already in your library" toast can't clobber
    /// active bulk-import progress. The UUID token guards auto-dismiss against stale timers.
    @Published var addConfirmation: AddConfirmation?
    @Published var errorMessage: String?
    /// All reference titles for smart keyword extraction (unaffected by filters).
    @Published private(set) var allReferenceTitles: [String] = []
    /// Tag map for table view: referenceId → [Tag]
    @Published var referenceTagMap: [Int64: [Tag]] = [:]
    @Published var propertyDefs: [PropertyDefinition] = []
    @Published var customPropertyValueMap: [Int64: [Int64: String]] = [:]
    /// Column configuration for the table view (persisted via @AppStorage in ContentView)
    @Published var tableSorts: [ViewSort] = [.defaultSort] {
        didSet { recomputeIsDirty() }
    }
    @Published var viewFilters: [ViewFilter] = [] {
        didSet { recomputeIsDirty() }
    }
    @Published var viewGroupBy: GroupConfig? = nil {
        didSet { recomputeIsDirty() }
    }
    /// Per-view wrap state. Presence of a `customizationID` ≡ wrapped.
    @Published var viewColumnWraps: Set<String> = [] {
        didSet { recomputeIsDirty() }
    }
    @Published private(set) var isCurrentViewDirty: Bool = false
    /// All saved database views
    @Published var databaseViews: [DatabaseView] = []

    // MARK: - Private state
    let db: AppDatabase
    private var cancellables = Set<AnyCancellable>()
    /// Cancellable for the active reference ValueObservation subscription.
    private var referenceObserverCancellable: AnyCancellable?
    /// Scope captured when the active reference observation was created.
    private var observedReferenceScope: ReferenceScope?
    /// Timer-based debounce task for search input.
    private var searchDebounceTask: Task<Void, Never>?
    /// The filter currently applied to the database query.
    private var activeFilter = ReferenceFilter()
    /// Wired up by `ContentView` from its `@EnvironmentObject` so import
    /// flows can kick the PDF upload-queue drainer immediately. Weak to
    /// avoid retain cycles — the coordinator outlives the view model.
    weak var syncCoordinator: SyncCoordinator?
    weak var pdfDownloadCoordinator: PDFDownloadCoordinator?

    init(db: AppDatabase = .shared) {
        self.db = db
        setupObservation()
    }

    // MARK: - Observation setup

    private func setupObservation() {
        db.observeTags()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.errorMessage = "Tags refresh failed: \(error.localizedDescription)"
                    }
                },
                receiveValue: { [weak self] tags in
                    self?.tags = tags
                }
            )
            .store(in: &cancellables)

        db.observePendingMetadataIntakes()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.errorMessage = "Pending metadata refresh failed: \(error.localizedDescription)"
                    }
                },
                receiveValue: { [weak self] items in
                    self?.pendingMetadataIntakes = items
                }
            )
            .store(in: &cancellables)

        db.observeDatabaseViews()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] views in
                    self?.databaseViews = views
                    self?.selectDefaultViewIfNeeded()
                }
            )
            .store(in: &cancellables)

        db.observeReferenceTagMappings()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] map in
                    self?.referenceTagMap = map
                }
            )
            .store(in: &cancellables)

        db.observePropertyDefinitions()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] defs in
                    self?.propertyDefs = defs
                }
            )
            .store(in: &cancellables)

        db.observeAllPropertyValues()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] map in
                    self?.customPropertyValueMap = map
                }
            )
            .store(in: &cancellables)

        // Observe all reference titles for smart keyword extraction.
        // Throttle: a sync batch commits many `reference` rows back-to-back,
        // and we don't want each commit to retrigger the full sidebar
        // keyword recompute on main. 150 ms / latest coalesces the burst.
        db.observeReferences()
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] refs in
                    self?.allReferenceTitles = refs.map(\.title)
                }
            )
            .store(in: &cancellables)

        // Start the initial reference observation with no filter.
        rebuildReferenceObserver()
    }

    /// (Re-)subscribe to the database with the current scope + filter.
    /// Called whenever the sidebar selection or the debounced filter changes.
    private func rebuildReferenceObserver() {
        referenceObserverCancellable?.cancel()

        let scope = currentReferenceScope
        observedReferenceScope = scope
        var filter = activeFilter

        if case .titleKeyword(let word) = selectedSidebar {
            filter.keyword = word
            filter.titleOnly = true
        }

        referenceObserverCancellable = db
            .observeReferences(scope: scope, filter: filter, limit: 0)
            // Coalesce bursty commits. Sync apply batches commit reference
            // rows back-to-back; each commit re-fires `fetchReferences` (a
            // SQLite query — joins under `.tag` scope, FTS only when a
            // keyword filter is active) and emits to main. Without this,
            // the burst saturates the main thread and starves any PDF
            // reader window currently rendering. `latest: true` keeps the
            // freshest snapshot per window.
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let error) = completion {
                        self?.errorMessage = "References refresh failed: \(error.localizedDescription)"
                    }
                },
                receiveValue: { [weak self] refs in
                    self?.references = refs
                }
            )
    }

    var currentReferenceScope: ReferenceScope {
        let scope: ReferenceScope
        switch selectedSidebar {
        case .allReferences, .titleKeyword:
            scope = .all
        case .tag(let id):          scope = .tag(id)
        case .view(let viewId):
            if let dbView = databaseViews.first(where: { $0.id == viewId }) {
                switch dbView.parsedScope {
                case .all: scope = .all
                case .tag(let id): scope = .tag(id)
                }
            } else {
                scope = .all
            }
        }
        return scope
    }

    private var isObservingCurrentReferenceScope: Bool {
        guard let observedReferenceScope else { return false }
        switch (observedReferenceScope, currentReferenceScope) {
        case (.all, .all):
            return true
        case let (.tag(observed), .tag(current)):
            return observed == current
        default:
            return false
        }
    }


    /// Debounce raw search text by 250 ms before rebuilding the DB observer.
    private func scheduleSearchDebounce() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
            guard !Task.isCancelled else { return }
            let parsed = SearchQuery.parse(self.searchText)
            var filter = ReferenceFilter()
            filter.keyword      = parsed.keyword
            filter.author       = parsed.author
            filter.yearFrom     = parsed.yearFrom
            filter.yearTo       = parsed.yearTo
            filter.journal      = parsed.journal
            filter.referenceType = parsed.type
            self.activeFilter = filter
            self.rebuildReferenceObserver()
        }
    }

    /// Convenience accessor — references are already filtered by the DB query.
    var filteredReferences: [Reference] { references }

    /// Top title keywords extracted from all reference titles.
    var titleKeywords: [(word: String, count: Int)] {
        let stopWords: Set<String> = [
            // English
            "the", "and", "for", "with", "from", "that", "this", "are", "was",
            "were", "been", "being", "have", "has", "had", "not", "but", "its",
            "can", "may", "will", "should", "could", "would", "into", "than",
            "also", "where", "when", "how", "what", "which", "who", "whom",
            "why", "all", "any", "each", "every", "both", "few", "more",
            "most", "other", "some", "such", "only", "own", "same", "then",
            "too", "very", "just", "about", "above", "after", "again",
            "below", "between", "during", "further", "here", "once", "there",
            "these", "those", "through", "under", "until", "while",
            "over", "out", "off", "down", "before", "our", "your", "his",
            "her", "their", "its", "does", "did", "doing",
            "using", "based", "via", "new", "one", "two", "study", "analysis",
            "case", "approach", "method", "model", "data", "results", "review",
            "research", "paper", "effect", "effects", "use",
            // Chinese
            "的", "了", "在", "是", "我", "有", "和", "就", "不", "人",
            "都", "一", "一个", "上", "也", "很", "到", "说", "要", "去",
            "你", "会", "着", "没有", "看", "好", "自己", "这", "他", "她",
            "对", "中", "与", "及", "或", "等", "基于", "研究", "分析",
        ]

        var freq: [String: Int] = [:]
        for title in allReferenceTitles {
            let lower = title.lowercased()
            let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
            for word in Set(words) {
                freq[word, default: 0] += 1
            }
        }

        return freq
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map { (word: $0.key, count: $0.value) }
    }

    func deleteReferences(_ refs: [Reference]) {
        let ids = refs.compactMap(\.id)
        do {
            let pdfPaths = try db.deleteReferencesReturningPDFPaths(ids: ids)
            pdfDownloadCoordinator?.referencesWereDeleted(ids)
            for path in pdfPaths {
                PDFService.deletePDF(at: path)
            }
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    struct AddConfirmation: Equatable, Identifiable {
        let id: UUID
        let message: String
    }

    /// User-facing toast text for a single-add outcome. Static + pure so it's unit-testable.
    static func addConfirmationMessage(for result: AppDatabase.ReferenceSaveResult) -> String {
        switch result {
        case .created:  return String(localized: "Added to library", bundle: .module)
        case .existing: return String(localized: "Already in your library", bundle: .module)
        }
    }

    /// Shows a transient single-add confirmation toast and auto-dismisses it. The UUID token
    /// ensures an older dismissal timer can't clear a newer message.
    func flashAddConfirmation(_ message: String) {
        let confirmation = AddConfirmation(id: UUID(), message: message)
        addConfirmation = confirmation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.addConfirmation?.id == confirmation.id {
                self?.addConfirmation = nil
            }
        }
    }

    @discardableResult
    func saveReference(_ ref: inout Reference) -> AppDatabase.ReferenceSaveResult? {
        ref.dateModified = Date()
        do {
            return try db.saveReference(&ref)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            return nil
        }
    }

    func setTags(forReference refId: Int64, tagIds: [Int64]) {
        do {
            try db.setTags(forReference: refId, tagIds: tagIds)
        } catch {
            errorMessage = "Set tags failed: \(error.localizedDescription)"
        }
    }

    /// Creates a new tag and returns its id. Assignment is the caller's job —
    /// this separation lets `TagPickerPopover` stay the single source of truth
    /// for a reference's tag set, avoiding a race with its `onCommit` flow.
    func createTag(name: String) -> Int64? {
        do {
            let color = ColorPalette.nextUnused(excluding: Set(tags.map(\.color)))
            var tag = Tag(name: name, color: color)
            try db.saveTag(&tag)
            return tag.id
        } catch {
            errorMessage = "Create tag failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func saveManualReference(
        _ ref: inout Reference,
        reviewedBy: String = "manual-entry",
        pdfFilename: String? = nil
    ) -> AppDatabase.ReferenceSaveResult? {
        if ref.id == nil && !ref.verificationStatus.isLibraryReady {
            ref = MetadataVerifier.manuallyVerified(ref, reviewedBy: reviewedBy)
        }
        let result = saveReference(&ref)
        if let pdfFilename, let id = ref.id {
            do {
                try db.attachImportedPDFs(rowIds: [id], filenames: [pdfFilename])
                let coordinator = syncCoordinator
                Task { await coordinator?.kickPDFUploadDrainer() }
            } catch {
                errorMessage = "Attach PDF failed: \(error.localizedDescription)"
            }
        }
        return result
    }

    func batchImportReferences(_ refs: [Reference]) {
        do {
            _ = try db.batchImportReferences(refs)
        } catch {
            errorMessage = "Batch import failed: \(error.localizedDescription)"
        }
    }

    func persistMetadataResolution(
        _ result: MetadataResolutionResult,
        options: MetadataPersistenceOptions
    ) -> MetadataPersistenceResult? {
        do {
            return try db.persistMetadataResolution(result, options: options)
        } catch {
            errorMessage = "Metadata persistence failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func deletePendingMetadataIntake(_ intake: MetadataIntake) -> Bool {
        guard let id = intake.id else { return false }
        do {
            try db.deleteMetadataIntake(id: id)
            return true
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            return false
        }
    }

    func saveTag(_ tag: inout Tag) {
        do {
            try db.saveTag(&tag)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func deleteTag(id: Int64) {
        do {
            try db.deleteTag(id: id)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Probe whether a tag can be deleted, fail-closed. Returns the in-use
    /// reference count (→ confirm) or nil (deleted outright because unused, or
    /// Tags property not resolvable — a safe no-op). Routes through the seeded
    /// Tags PropertyDefinition so it shares deletePropertyOption's counting path.
    func probeDeleteTag(id: Int64) -> Int? {
        guard let tagsPropId = propertyDefs.first(where: { $0.isTags })?.id else { return nil }
        return db.probeDeletePropertyOption(propertyId: tagsPropId, value: String(id))
    }

    func saveDatabaseView(_ view: inout DatabaseView) {
        do {
            try db.saveDatabaseView(&view)
        } catch {
            errorMessage = "Save view failed: \(error.localizedDescription)"
        }
    }

    func deleteDatabaseView(id: Int64) {
        do {
            try db.deleteDatabaseView(id: id)
            if case .view(let selectedId) = selectedSidebar, selectedId == id {
                selectSidebar(.allReferences, stashCurrentDraft: false)
            }
        } catch {
            errorMessage = "Delete view failed: \(error.localizedDescription)"
        }
    }

    func reorderDatabaseViews(_ orderedIds: [Int64]) {
        do {
            try db.reorderDatabaseViews(orderedIds)
        } catch {
            errorMessage = "Reorder views failed: \(error.localizedDescription)"
        }
    }

    func createDatabaseView(
        name: String,
        icon: String = ViewIconCatalog.defaultIcon,
        scope: ViewScope = .all,
        stashCurrentDraft: Bool = true
    ) {
        let maxOrder = databaseViews.map(\.displayOrder).max() ?? 0
        var view = DatabaseView(
            name: name,
            icon: icon,
            scope: scope,
            isDefault: false,
            displayOrder: maxOrder + 1
        )
        saveDatabaseView(&view)
        if let id = view.id {
            selectSidebar(.view(id), stashCurrentDraft: stashCurrentDraft)
        }
    }

    func updateDatabaseView(id: Int64, name: String, icon: String) {
        guard var view = databaseViews.first(where: { $0.id == id }) else { return }
        view.name = name
        view.icon = icon
        saveDatabaseView(&view)
    }

    /// Stash of per-view edits that haven't been saved yet. Keyed by view id.
    /// On view switch we record the leaving view's edits here; on return we
    /// restore them instead of reloading from persisted state.
    private struct ViewDraft {
        var filters: [ViewFilter]
        var sorts: [ViewSort]
        var groupBy: GroupConfig?
        var columnWraps: Set<String>
    }
    private var viewDrafts: [Int64: ViewDraft] = [:]

    private var currentDBView: DatabaseView? {
        guard case .view(let id) = selectedSidebar else { return nil }
        return databaseViews.first(where: { $0.id == id })
    }

    private func syncColumnConfigFromView() {
        let config: ViewDraft

        guard let dbView = currentDBView, let id = dbView.id else {
            applyColumnConfig(ViewDraft(
                filters: [],
                sorts: [.defaultSort],
                groupBy: nil,
                columnWraps: []
            ))
            return
        }
        if let draft = viewDrafts[id] {
            config = draft
        } else {
            config = ViewDraft(
                filters: dbView.parsedFilters,
                sorts: dbView.parsedSorts,
                groupBy: dbView.parsedGroupBy,
                columnWraps: dbView.parsedColumnWraps
            )
        }
        applyColumnConfig(config)
    }

    private func applyColumnConfig(_ config: ViewDraft) {
        if tableSorts != config.sorts { tableSorts = config.sorts }
        if viewFilters != config.filters { viewFilters = config.filters }
        if viewGroupBy != config.groupBy { viewGroupBy = config.groupBy }
        if viewColumnWraps != config.columnWraps { viewColumnWraps = config.columnWraps }
    }

    private func stashDraftIfDirty(for item: SidebarItem) {
        guard case .view(let id) = item,
              let dbView = databaseViews.first(where: { $0.id == id }) else { return }
        let dirty = viewFilters != dbView.parsedFilters
            || tableSorts != dbView.parsedSorts
            || viewGroupBy != dbView.parsedGroupBy
            || viewColumnWraps != dbView.parsedColumnWraps
        if dirty {
            viewDrafts[id] = ViewDraft(
                filters: viewFilters,
                sorts: tableSorts,
                groupBy: viewGroupBy,
                columnWraps: viewColumnWraps
            )
        } else {
            viewDrafts.removeValue(forKey: id)
        }
    }

    private func recomputeIsDirty() {
        guard let dbView = currentDBView else {
            isCurrentViewDirty = false
            return
        }
        isCurrentViewDirty = viewFilters != dbView.parsedFilters
            || tableSorts != dbView.parsedSorts
            || viewGroupBy != dbView.parsedGroupBy
            || viewColumnWraps != dbView.parsedColumnWraps
    }

    var currentViewName: String? { currentDBView?.name }

    func saveDraftForCurrentView() {
        guard var dbView = currentDBView, let id = dbView.id else { return }
        dbView.parsedFilters = viewFilters
        dbView.parsedSorts = tableSorts
        dbView.parsedGroupBy = viewGroupBy
        dbView.parsedColumnWraps = viewColumnWraps
        saveDatabaseView(&dbView)
        // `observeDatabaseViews` updates `databaseViews` asynchronously; patch
        // our local copy synchronously so the dirty-check baseline is correct
        // on the next recompute.
        if let idx = databaseViews.firstIndex(where: { $0.id == id }) {
            databaseViews[idx] = dbView
        }
        viewDrafts.removeValue(forKey: id)
        recomputeIsDirty()
    }

    func discardDraftForCurrentView() {
        guard let dbView = currentDBView, let id = dbView.id else { return }
        applyColumnConfig(ViewDraft(
            filters: dbView.parsedFilters,
            sorts: dbView.parsedSorts,
            groupBy: dbView.parsedGroupBy,
            columnWraps: dbView.parsedColumnWraps
        ))
        viewDrafts.removeValue(forKey: id)
    }

    /// Auto-selects the default database view at startup — but ONCE. Re-running it on every
    /// `databaseViews` emission (sync, view reorder, late load) would yank the user back to the
    /// default view after they (or an import/search reveal) navigated to `.allReferences`,
    /// re-hiding any row the default view's filters exclude.
    private var hasAppliedDefaultView = false
    func selectDefaultViewIfNeeded() {
        guard !hasAppliedDefaultView else { return }
        if case .allReferences = selectedSidebar,
           let defaultView = databaseViews.first(where: \.isDefault),
           let id = defaultView.id {
            hasAppliedDefaultView = true
            selectSidebar(.view(id), stashCurrentDraft: false)
        }
    }

}

struct ContentView: View {
    private enum MainDestination { case home, library }
    private struct SuggestedReferenceImport: Identifiable {
        let id = UUID()
        let url: String
    }

    @StateObject private var viewModel: LibraryViewModel
    @StateObject private var homeRenderer: ChatTranscriptController
    @StateObject private var homeSession: ChatSessionController
    @EnvironmentObject private var pdfDownloadCoordinator: PDFDownloadCoordinator
    @EnvironmentObject private var scheduledJobCoordinator: ScheduledJobCoordinator
    @Environment(\.syncCoordinator) private var syncCoordinator: SyncCoordinator?
    #if canImport(Sparkle)
    @Environment(UpdateController.self) private var updateController
    #endif
    @State private var showSearch = false
    @State private var showPropertyManager = false
    @State private var showInspector = true
    @State private var inspectorWidth: CGFloat = 380
    @State private var showAddReference = false
    @State private var addReferenceInitialType: ReferenceType = .journalArticle
    @State private var showAddReferenceFlow = false
    @State private var suggestedReferenceImport: SuggestedReferenceImport?
    @State private var addReferenceFileHandoff = DeferredSheetHandoff<[MaterializedImportSource]>()
    @State private var showBatchImport = false
    @State private var preparedMetadataImportsAfterBatchDismiss: [PreparedMetadataImport]?
    @State private var importReviewSession: ImportReviewSession?
    /// Monotonic token owned by `importFilesWithMetadata`. Each batch captures
    /// its value; the batch's own auto-clear timer only wipes `importProgress`
    /// if it still matches, so a stale timer from an earlier batch can't erase
    /// a newer (fast markdown-only) batch's summary toast.
    @State private var importGeneration = 0
    @State private var showZoteroLibraryImport = false
    @State private var zoteroLibraryImportHandoff = DeferredSheetHandoff<ZoteroLibraryImportRequest>()
    @State private var showPendingMetadataQueue = false
    @State private var scopedPendingMetadataIntakes: [MetadataIntake]?
    @State private var pendingQueueNotice: PendingQueueNotice?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var mainDestination: MainDestination = .home
    /// Once the library has been mounted, keep its table hierarchy alive while
    /// Home is visible. Rebuilding SwiftUI's macOS Table on every navigation is
    /// noticeably slower than toggling the retained surface's visibility.
    @State private var hasPresentedLibrary = false
    @State private var homeDraft = ""
    @State private var homeSelectedMentions: [PaperMentionSelection] = []
    @State private var homeActivityRailVisible = true
    @State private var homeActivityOverlayPresented = false
    @State private var homeActivityWidth: CGFloat = 380
    @State private var homeUsesCompactLayout = false
    @State private var homeUnreadOutcome: AssistantTurnOutcome.Phase?
    @State private var scheduledJobsPresentation: ScheduledJobsPresentation?
    @State private var homePresentedScheduledRunID: String?
    @State private var hostingWindowBox = HostingWindowBox()
    @State private var selectedId: Int64?
    @State private var tableScrollRequest = 0
    @State private var columnConfigs: [ColumnConfig] = {
        guard let data = UserDefaults.standard.data(forKey: RubienPreferences.columnConfigsKey),
              let decoded = try? JSONDecoder().decode([ColumnConfig].self, from: data) else {
            return ColumnConfig.defaultColumns
        }
        return decoded
    }()

    @MainActor
    init() {
        let database = AppDatabase.shared
        let renderer = ChatTranscriptController()
        _viewModel = StateObject(wrappedValue: LibraryViewModel(db: database))
        _homeRenderer = StateObject(wrappedValue: renderer)
        _homeSession = StateObject(wrappedValue: ReaderChatSession.makeLibrary(
            transcript: renderer,
            database: database))
    }

    private struct PendingQueueNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Per-file result of a single PDF import, surfaced to the batch
    /// coordinator's summary. Never carries UI-state mutations — the
    /// coordinator owns `isImporting`/`importProgress`.
    private enum PDFBatchImportOutcome {
        case imported(title: String)
        case queued(MetadataIntake)
        case failed(String)
    }

    private var metadataResolver: MetadataResolver {
        MetadataResolver()
    }

    private var selectedReference: Reference? {
        guard let selectedId else { return nil }
        return viewModel.filteredReferences.first { $0.id == selectedId }
    }

    private var homeHasAttention: Bool {
        homeSession.pendingApproval != nil
            || homeSession.isResponding
            || homeUnreadOutcome == .succeeded
            || homeUnreadOutcome == .failed
    }

    @ViewBuilder
    private var homeAttentionIcon: some View {
        if homeSession.pendingApproval != nil {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else if homeSession.isResponding {
            ProgressView().controlSize(.small)
        } else if homeUnreadOutcome == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
        }
    }

    private var pendingMetadataIntakesForReview: [MetadataIntake] {
        PendingMetadataIntakePresentation.intakesForReview(
            observedPending: viewModel.pendingMetadataIntakes,
            scopedPending: scopedPendingMetadataIntakes
        )
    }

    /// The leading toolbar's flat controls, in order: Manage Properties, Search, the
    /// Add Reference button, then the More-import menu. Rendered with
    /// `ToolbarHoverButtonStyle` (no glass capsule, just a light hover) and a
    /// shared `.titleAndIcon` label style. The enclosing `ToolbarItemGroup` opts
    /// out of the macOS 26 shared glass platter so these stay flat.
    @ViewBuilder
    private var leadingToolbarButtons: some View {
        Group {
            if mainDestination == .library {
                Button {
                    showPropertyManager.toggle()
                } label: {
                    Label("Manage Properties", systemImage: "slider.horizontal.3")
                }
                .help("Manage properties")
                .popover(isPresented: $showPropertyManager) {
                    PropertyManagerPopover(
                        propertyDefs: Binding(
                            get: { viewModel.propertyDefs },
                            set: { viewModel.propertyDefs = $0 }
                        ),
                        onToggleVisibility: { propId, visible in
                            try? viewModel.db.togglePropertyVisibility(id: propId, visible: visible)
                        },
                        onDelete: { propId in
                            try? viewModel.db.deletePropertyDefinition(id: propId)
                        },
                        onReorder: { orderedIds in
                            try? viewModel.db.reorderProperties(orderedIds)
                        },
                        onCreateProperty: { name, type in
                            let maxOrder = viewModel.propertyDefs.map(\.sortOrder).max() ?? 0
                            var newProp = PropertyDefinition(
                                name: name, type: type, sortOrder: maxOrder + 1, isDefault: false, isVisible: true
                            )
                            try? viewModel.db.savePropertyDefinition(&newProp)
                        },
                        onRenameProperty: { propId, newName in
                            if var prop = viewModel.propertyDefs.first(where: { $0.id == propId }) {
                                prop.name = newName
                                try? viewModel.db.savePropertyDefinition(&prop)
                            }
                        }
                    )
                }
            }

            Button {
                showSearch = true
            } label: {
                Label(String(localized: "common.search", bundle: .module), systemImage: "magnifyingglass")
            }
            .help(String(localized: "Search references", bundle: .module))
            .keyboardShortcut("f", modifiers: .command)

            Button {
                showAddReferenceFlow = true
            } label: {
                Label(String(localized: "content.toolbar.addReference", bundle: .module), systemImage: "square.and.arrow.down")
            }
            .help(String(localized: "content.toolbar.addReference.help", bundle: .module))

            if !viewModel.pendingMetadataIntakes.isEmpty {
                Button {
                    scopedPendingMetadataIntakes = nil
                    showPendingMetadataQueue = true
                } label: {
                    HStack(spacing: 6) {
                        Label(String(localized: "content.toolbar.pendingQueue", bundle: .module), systemImage: "clock.badge.exclamationmark")
                        Text("\(viewModel.pendingMetadataIntakes.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                .help(String(localized: "Open the pending metadata queue to review candidates or confirm manually", bundle: .module))
            }

            Menu {
                Button(String(localized: "content.toolbar.addManually", bundle: .module)) {
                    addReferenceInitialType = .journalArticle
                    showAddReference = true
                }
                Divider()
                // Only the import actions are gated while an import runs; manual
                // reference creation stays available (it was a standalone button before).
                Group {
                    Button(String(localized: "content.toolbar.batchImport", bundle: .module) + "…") { showBatchImport = true }
                    Divider()
                    Button(String(localized: "content.toolbar.importBibTeX", bundle: .module)) { importBibTeX() }
                    Button(String(localized: "content.toolbar.importRIS", bundle: .module)) { importRIS() }
                    Button(String(localized: "content.toolbar.importFromZotero", bundle: .module)) {
                        showZoteroLibraryImport = true
                    }
                }
                .disabled(viewModel.isImporting)
            } label: {
                Label(String(localized: "More import options", bundle: .module), systemImage: "tray.and.arrow.down")
            }
            .menuStyle(.button)
            .help(String(localized: "More import options", bundle: .module))
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(ToolbarHoverButtonStyle())
    }

    /// Toolbar toggle that shows / hides the floating detail panel.
    @ViewBuilder
    private var detailsToggleButton: some View {
        Button {
            showInspector.toggle()
        } label: {
            Label("Details", systemImage: "sidebar.trailing")
        }
        .help("Show or hide the details panel")
    }

    /// The reference detail as a floating glass card that overlays the table:
    /// the table stays full-width and visible (blurred) behind the translucent
    /// glass, and the card can be toggled away. Rounded + shadowed so it reads as
    /// floating. Visibility is the caller's (`showInspector`).
    @ViewBuilder
    private var detailPanel: some View {
        Group {
            if let ref = selectedReference {
                ReferenceDetailView(
                    reference: ref,
                    allTags: viewModel.tags,
                    liveTags: viewModel.referenceTagMap[ref.id ?? -1] ?? [],
                    db: viewModel.db,
                    isActive: mainDestination == .library,
                    onSave: { updated in
                        var r = updated
                        viewModel.saveReference(&r)
                    },
                    onDelete: {
                        deleteReferences([ref])
                    },
                    onOpenPDFReader: { r in
                        ReaderWindowManager.shared.openPDFReader(for: r, db: viewModel.db)
                    },
                    onOpenWebReader: { r in
                        ReaderWindowManager.shared.openWebReader(for: r, db: viewModel.db)
                    },
                    onUpdateTags: { refId, tagIds in viewModel.setTags(forReference: refId, tagIds: tagIds) },
                    onCreateTag: { name in viewModel.createTag(name: name) },
                    onDeleteTag: { tagId in viewModel.deleteTag(id: tagId) },
                    deleteTagUnlessInUse: { tagId in viewModel.probeDeleteTag(id: tagId) },
                    pdfOperations: Binding(
                        get: { pdfDownloadCoordinator.operations },
                        set: { pdfDownloadCoordinator.operations = $0 }
                    ),
                    propertyDefs: Binding(
                        get: { viewModel.propertyDefs },
                        set: { viewModel.propertyDefs = $0 }
                    )
                )
            } else if selectedId != nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a reference", bundle: .module)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(String(format: String(localized: "%d references", bundle: .module), viewModel.references.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .neutralGlassCard(cornerRadius: 14)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                databaseViews: viewModel.databaseViews,
                titleKeywords: viewModel.titleKeywords,
                selection: Binding(
                    get: { viewModel.selectedSidebar },
                    set: { showLibrary(selecting: $0) }),
                isHomeSelected: mainDestination == .home,
                homeIsResponding: homeSession.isResponding,
                homeNeedsApproval: homeSession.pendingApproval != nil,
                homeUnreadOutcome: homeUnreadOutcome,
                onSelectHome: showHome,
                referenceCount: viewModel.references.count,
                onCreateView: { name, icon in
                    viewModel.createDatabaseView(
                        name: name,
                        icon: icon,
                        stashCurrentDraft: mainDestination == .library
                    )
                },
                onDeleteView: { viewModel.deleteDatabaseView(id: $0) },
                onUpdateView: { id, name, icon in viewModel.updateDatabaseView(id: id, name: name, icon: icon) },
                onReorderViews: { viewModel.reorderDatabaseViews($0) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            ZStack {
                AgentHomeView(
                    session: homeSession,
                    renderer: homeRenderer,
                    database: viewModel.db,
                    isActive: mainDestination == .home,
                    draft: $homeDraft,
                    selectedMentions: $homeSelectedMentions,
                    activityRailVisible: $homeActivityRailVisible,
                    activityOverlayPresented: $homeActivityOverlayPresented,
                    activityWidth: $homeActivityWidth,
                    scheduledJobsPresentation: $scheduledJobsPresentation,
                    presentedScheduledRunID: $homePresentedScheduledRunID,
                    onOpenReference: openReader,
                    onOpenPaperSource: { ChatExternalLinkOpener.open($0) },
                    onAddPaperSource: beginSuggestedReferenceImport,
                    libraryIsEmpty: viewModel.references.isEmpty,
                    onAddPapers: { showAddReferenceFlow = true },
                    onImportPDFs: { showAddReferenceFlow = true },
                    onCompactLayoutChange: { homeUsesCompactLayout = $0 },
                    onOpenScheduledRun: openScheduledRun,
                    onContinueScheduledRun: continueScheduledRun,
                    onRetryScheduledRunImport: retryScheduledRunImport)
                .retainedDetailSurface(isActive: mainDestination == .home)

                if hasPresentedLibrary || mainDestination == .library {
                    ReferenceTableView(
                references: viewModel.filteredReferences,
                tagMap: viewModel.referenceTagMap,
                allTags: viewModel.tags,
                selectedId: selectedId,
                onSelect: { selectedId = $0 },
                onDelete: { deleteReferences($0) },
                onRefreshMetadata: { refs in refreshMetadata(for: refs) },
                onUpdateReference: { updated in
                    var ref = updated
                    viewModel.saveReference(&ref)
                },
                onUpdateTags: { refId, tagIds in viewModel.setTags(forReference: refId, tagIds: tagIds) },
                onCreateTag: { name in viewModel.createTag(name: name) },
                onDeleteTag: { tagId in viewModel.deleteTag(id: tagId) },
                deleteTagUnlessInUse: { tagId in viewModel.probeDeleteTag(id: tagId) },
                onCreateOption: { propId, optionValue in
                    guard var prop = viewModel.propertyDefs.first(where: { $0.id == propId }) else { return }
                    let color = ColorPalette.nextUnused(excluding: Set(prop.options.map(\.color)))
                    var options = prop.options
                    options.append(SelectOption(value: optionValue, color: color))
                    prop.options = options
                    try? viewModel.db.savePropertyDefinition(&prop)
                },
                // Confirmed clear: drop the option and clear it from every
                // reference that holds it (the picker only reaches this after
                // the user confirms an in-use delete, or for an unused option).
                onDeleteOption: { propId, optionValue in
                    try? viewModel.db.deletePropertyOption(propertyId: propId, value: optionValue, clearInUse: true)
                },
                // Fail-closed strict probe (see AppDatabase.probeDeletePropertyOption):
                // deletes an unused option outright (→ nil), reports the in-use
                // count so the picker can confirm (→ count), never clears on an
                // unexpected error.
                deleteUnlessInUse: { propId, optionValue in
                    viewModel.db.probeDeletePropertyOption(propertyId: propId, value: optionValue)
                },
                isRefreshingMetadata: viewModel.isImporting,
                onDoubleClick: { refId in
                    openReader(for: refId)
                },
                columnConfigs: $columnConfigs,
                sorts: $viewModel.tableSorts,
                filters: $viewModel.viewFilters,
                propertyDefs: Binding(
                    get: { viewModel.propertyDefs },
                    set: { viewModel.propertyDefs = $0 }
                ),
                db: viewModel.db,
                customPropertyValueMap: viewModel.customPropertyValueMap,
                groupBy: $viewModel.viewGroupBy,
                viewColumnWraps: $viewModel.viewColumnWraps,
                viewName: viewModel.currentViewName,
                isDirty: viewModel.isCurrentViewDirty,
                onSaveView: { viewModel.saveDraftForCurrentView() },
                onDiscardView: { viewModel.discardDraftForCurrentView() },
                scrollRequest: tableScrollRequest,
                isActive: mainDestination == .library,
                pdfAttachmentRevision: pdfDownloadCoordinator.operations.revision
            )
            // The detail floats over the table (table stays full-width and shows
            // through the translucent glass), below the toolbar, shown only while
            // toggled on. Drag its leading edge to resize the width.
            .overlay(alignment: .trailing) {
                if showInspector {
                    FloatingPanel(width: $inspectorWidth, range: 280...640) {
                        detailPanel
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 6)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: showInspector)
            .retainedDetailSurface(isActive: mainDestination == .library)
                }
            }
        }
        .toolbar(content: {
            // Clear center item: anchors the toolbar layout so the trailing
            // details toggle is pushed to the far-right edge instead of packing
            // next to the leading group.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }
            // All primary actions live on the leading edge in one flat group:
            // Properties, Search, the add/import actions, then the More menu. On
            // macOS 26 the group opts out of the toolbar's shared Liquid Glass
            // platter (`sharedBackgroundVisibility`) so the buttons render flat
            // with only a light hover highlight, not as glass capsules.
            if #available(macOS 26.0, *) {
                ToolbarItemGroup(placement: .navigation) {
                    leadingToolbarButtons
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItemGroup(placement: .navigation) {
                    leadingToolbarButtons
                }
            }
            // The update pill trails the group (still leading-aligned), shown
            // only while an update is pending so its fixed spacer leaves no
            // phantom gap otherwise. It keeps its own accent style and likewise
            // opts out of the shared glass platter.
            #if canImport(Sparkle)
            if updateController.updateReadyToInstall {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .navigation)
                    ToolbarItem(placement: .navigation) {
                        UpdateIndicator()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        UpdateIndicator()
                    }
                }
            }
            #endif
            // Trailing toggle for the details panel, pushed to the far-right edge
            // by the clear principal item at the top of this toolbar.
            ToolbarItemGroup(placement: .primaryAction) {
                if mainDestination == .library {
                    if columnVisibility == .detailOnly, homeHasAttention {
                        Button(action: showHome) { homeAttentionIcon }
                            .help(homeSession.pendingApproval != nil
                                ? "Assistant approval needed"
                                : "Open Home Assistant")
                    }
                    detailsToggleButton
                } else {
                    Button {
                        if homeUsesCompactLayout {
                            homeActivityOverlayPresented.toggle()
                        } else {
                            homeActivityRailVisible.toggle()
                        }
                    } label: {
                        Label(
                            "Activity",
                            systemImage: (homeUsesCompactLayout && homeActivityOverlayPresented)
                                || (!homeUsesCompactLayout && homeActivityRailVisible)
                                ? "chart.bar.fill"
                                : "chart.bar")
                    }
                    .help(homeUsesCompactLayout
                        ? "Show reading activity"
                        : "Toggle reading activity")
                }
            }
        })
        .sheet(isPresented: $showAddReference) {
            AddReferenceView(
                onSave: { ref, pdfFilename in
                    var r = ref
                    let result = viewModel.saveManualReference(&r, pdfFilename: pdfFilename)
                    confirmAndReveal(r, result: result)
                },
                initialReferenceType: addReferenceInitialType
            )
        }
        .sheet(isPresented: $showAddReferenceFlow, onDismiss: finishDeferredReferenceImport) {
            addReferenceFlowSheet()
        }
        .sheet(
            item: $suggestedReferenceImport,
            onDismiss: finishDeferredReferenceImport
        ) { importRequest in
            addReferenceFlowSheet(initialInput: importRequest.url)
        }
        .sheet(isPresented: $showBatchImport, onDismiss: {
            guard let entries = preparedMetadataImportsAfterBatchDismiss else { return }
            preparedMetadataImportsAfterBatchDismiss = nil
            handlePreparedMetadataImports(entries)
        }) {
            BatchImportView(
                resolver: metadataResolver,
                onPrepared: { entries in
                    preparedMetadataImportsAfterBatchDismiss = entries
                    showBatchImport = false
                },
                onQueueResult: { result, input in
                    queueResolutionResult(
                        result,
                        options: MetadataPersistenceOptions(
                            sourceKind: .batchIdentifier,
                            originalInput: input
                        ),
                        successMessage: String(localized: "Queued for review", bundle: .module)
                    )
                }
            )
        }
        .sheet(item: $importReviewSession) { session in
            ImportReviewSheet(session: session)
        }
        .sheet(isPresented: $showZoteroLibraryImport, onDismiss: {
            guard let request = zoteroLibraryImportHandoff.takeAfterDismiss() else { return }
            prepareZoteroLibraryImport(request)
        }) {
            ZoteroLibraryImportSheet(
                db: viewModel.db,
                onConfirm: { request in
                    zoteroLibraryImportHandoff.stage(request)
                },
                onCancel: {}
            )
        }
        .overlay {
            if showSearch {
                SearchOverlay(
                    db: viewModel.db,
                    scope: mainDestination == .home ? .all : viewModel.currentReferenceScope,
                    isPresented: $showSearch,
                    onSelect: { ref in
                        revealReference(ref)
                    },
                    onDeleteMultiple: { refs in
                        deleteReferences(refs)
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            if let progress = viewModel.importProgress {
                FloatingProgressToast(
                    message: progress,
                    isSpinning: viewModel.isImporting
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progress)
            }
        }
        .overlay(alignment: .top) {
            if let confirmation = viewModel.addConfirmation {
                FloatingProgressToast(message: confirmation.message, isSpinning: false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(11)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: confirmation.id)
            }
        }
        .sheet(isPresented: $showPendingMetadataQueue, onDismiss: {
            scopedPendingMetadataIntakes = nil
        }) {
            PendingMetadataQueueView(
                database: viewModel.db,
                intakes: pendingMetadataIntakesForReview,
                resolver: metadataResolver,
                onConfirmed: { reference in
                    selectedId = reference.id
                },
                onDelete: { intake in
                    viewModel.deletePendingMetadataIntake(intake)
                }
            )
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 12) {
                if let notice = pendingQueueNotice {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "tray.full.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notice.title)
                                    .font(.headline)
                                Text(notice.message)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button {
                                pendingQueueNotice = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button(String(localized: "Open pending queue", bundle: .module)) {
                                pendingQueueNotice = nil
                                scopedPendingMetadataIntakes = nil
                                showPendingMetadataQueue = true
                            }
                            .buttonStyle(SLPrimaryButtonStyle())

                            Button(String(localized: "Later", bundle: .module)) {
                                pendingQueueNotice = nil
                            }
                            .buttonStyle(SLSecondaryButtonStyle())
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 360, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if !pdfDownloadCoordinator.orderedActivities.isEmpty {
                    PDFDownloadActivityPanel(
                        activities: pdfDownloadCoordinator.orderedActivities,
                        onRetry: pdfDownloadCoordinator.retry,
                        onDismiss: pdfDownloadCoordinator.dismiss
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
        .animation(.easeInOut(duration: 0.2), value: pendingQueueNotice)
        .animation(.easeInOut(duration: 0.2), value: pdfDownloadCoordinator.orderedActivities)
        .onChange(of: viewModel.references) { _, newRefs in
            guard let selectedId else { return }
            if !newRefs.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
            guard let id = note.userInfo?[RubienClipImportedKeys.id] as? Int64 else { return }
            showLibrary()
            selectedId = id
            columnVisibility = .all
        }
        .handlesExternalEvents(
            preferring: ["\(BrowserClipDeepLink.scheme):"],
            allowing: []
        )
        .onOpenURL { url in
            guard let destination = BrowserClipDeepLink.parse(url) else { return }
            openBrowserImport(destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rubienOpenAssistantPaperReference)) { note in
            guard let target = note.object as? NSWindow,
                  hostingWindowBox.window === target
            else { return }
            guard let id = note.userInfo?[ChatPaperActionNotificationKeys.referenceID] as? Int64,
                  let reference = try? viewModel.db.fetchReferences(ids: [id]).first
            else { return }
            openReader(for: reference)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rubienAddAssistantPaperSource)) { note in
            guard let target = note.object as? NSWindow,
                  hostingWindowBox.window === target
            else { return }
            guard let urlString = note.userInfo?[ChatPaperActionNotificationKeys.sourceURL] as? String
            else { return }
            beginSuggestedReferenceImport(urlString)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rubienOpenScheduledJobRun)) { note in
            if let target = note.object as? NSWindow,
               hostingWindowBox.window !== target {
                return
            }
            guard let runID = note.userInfo?[ScheduledJobNotifications.runIDKey] as? String,
                  let run = try? viewModel.db.fetchScheduledJobRun(id: runID)
            else { return }
            openScheduledRun(run)
        }
        .alert(String(localized: "Operation failed", bundle: .module), isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(String(localized: "common.ok", bundle: .module)) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(HostingWindowCapture(box: hostingWindowBox).frame(width: 0, height: 0))
        .onChange(of: columnConfigs) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: RubienPreferences.columnConfigsKey)
            }
        }
        .onChange(of: mainDestination) { _, destination in
            resignRetainedDetailEditorIfNeeded()
            if destination == .library {
                homeActivityOverlayPresented = false
            } else {
                viewModel.stashCurrentViewDraft()
                homeUnreadOutcome = nil
            }
        }
        .onChange(of: homeSession.turnOutcome) { _, outcome in
            guard mainDestination == .library else {
                homeUnreadOutcome = nil
                return
            }
            switch outcome.phase {
            case .succeeded, .failed:
                homeUnreadOutcome = outcome.phase
            case .responding, .approvalRequired:
                // A new hidden turn supersedes any older unread terminal badge.
                homeUnreadOutcome = nil
            case .idle, .cancelled, .superseded:
                break
            }
        }
        .onAppear {
            // Hand the sync coordinator to the view model so import flows
            // inside the model can kick the PDF upload-queue drainer.
            viewModel.syncCoordinator = syncCoordinator
            viewModel.pdfDownloadCoordinator = pdfDownloadCoordinator
            pdfDownloadCoordinator.syncCoordinator = syncCoordinator
        }
        .onDisappear {
            homeSession.teardown()
        }
    }

    private func openScheduledRun(_ run: ScheduledJobRun) {
        showHome()
        homePresentedScheduledRunID = run.id
        if run.status.isTerminal {
            scheduledJobCoordinator.markRunRead(id: run.id)
        }
        if case let .importLegacy(isRetry) =
            ScheduledJobFormatting.transcriptOpenAction(for: run)
        {
            importScheduledRun(
                run,
                isRetry: isRetry
            )
        }
    }

    private func retryScheduledRunImport(_ run: ScheduledJobRun) {
        importScheduledRun(run, isRetry: true)
    }

    private func importScheduledRun(_ run: ScheduledJobRun, isRetry: Bool) {
        Task { @MainActor in
            switch await homeSession.importScheduledLegacyResult(
                run,
                isRetry: isRetry
            ) {
            case .available:
                scheduledJobCoordinator.refresh()
                homePresentedScheduledRunID = run.id
                scheduledJobCoordinator.markRunRead(id: run.id)
            case let .openLocal(conversationID):
                scheduledJobCoordinator.refresh()
                homePresentedScheduledRunID = nil
                homeSession.resume(AgentSessionSummary(
                    id: conversationID,
                    preview: scheduledJobCoordinator.job(id: run.jobId)?.name ?? "",
                    date: run.activityAt
                ))
                scheduledJobCoordinator.markRunRead(id: run.id)
            case .deletedLocally, .needsRetry:
                scheduledJobCoordinator.refresh()
                homePresentedScheduledRunID = run.id
                scheduledJobCoordinator.markRunRead(id: run.id)
            case .unavailable:
                scheduledJobCoordinator.refresh()
                homePresentedScheduledRunID = run.id
            case .superseded:
                break
            }
        }
    }

    private func continueScheduledRun(_ run: ScheduledJobRun) {
        guard scheduledJobCoordinator.activeRun?.id != run.id else { return }
        do {
            try scheduledJobCoordinator.ensureAssistantExecutionOwner()
            let child = try viewModel.db.createScheduledAssistantContinuation(
                runID: run.id
            )
            homePresentedScheduledRunID = nil
            homeSession.resume(AgentSessionSummary(
                id: child.id,
                preview: scheduledJobCoordinator.job(id: run.jobId)?.name ?? "",
                date: child.lastActivityAt
            ))
            scheduledJobCoordinator.markRunRead(id: run.id)
        } catch {
            homePresentedScheduledRunID = nil
            presentRecentScheduledRuns(message: error.localizedDescription)
        }
    }

    private func presentRecentScheduledRuns(message: String) {
        showHome()
        scheduledJobsPresentation = ScheduledJobsPresentation(message: message)
    }

    private func importBibTeX() {
        guard let url = OpenPanelPicker.pickBibTeXFile() else { return }
        prepareStandardReferenceImport(
            from: url,
            format: .bibTeX
        )
    }

    private func revealReference(_ reference: Reference) {
        guard let id = reference.id else { return }
        // Land on the unfiltered .allReferences scope, which always renders the
        // row. Never the default saved view — its filters could hide the row.
        showLibrary(selecting: .allReferences, preemptsInitialDefaultView: true)
        selectedId = id
        tableScrollRequest += 1
        columnVisibility = .all
    }

    private func openBrowserImport(_ destination: BrowserClipDeepLinkDestination) {
        switch destination {
        case .reference(let id):
            guard let reference = try? viewModel.db.fetchReferences(ids: [id]).first else { return }
            revealReference(reference)
        case .pendingIntake(let id):
            guard let intake = try? viewModel.db.fetchPendingMetadataIntake(id: id) else { return }
            showLibrary()
            scopedPendingMetadataIntakes = PendingMetadataIntakePresentation.scopedIntakes(
                from: [intake]
            )
            pendingQueueNotice = nil
            showPendingMetadataQueue = true
        }
    }

    /// Single-add follow-through: confirmation toast (created vs duplicate) + reveal the row.
    /// `result == nil` means the save failed and already surfaced an error alert.
    private func confirmAndReveal(_ reference: Reference, result: AppDatabase.ReferenceSaveResult?) {
        guard let result else { return }
        viewModel.flashAddConfirmation(LibraryViewModel.addConfirmationMessage(for: result))
        revealReference(reference)
    }

    private func importRIS() {
        guard let url = OpenPanelPicker.pickRISFile() else { return }
        prepareStandardReferenceImport(
            from: url,
            format: .ris
        )
    }

    private func handlePreparedMetadataImports(_ entries: [PreparedMetadataImport]) {
        guard !entries.isEmpty else { return }

        guard BatchImportPresentation.shouldReview(requestedInputCount: entries.count) else {
            let entry = entries[0]
            switch entry.result {
            case .verified(let envelope):
                viewModel.batchImportReferences([envelope.reference])
            case .candidate, .blocked, .seedOnly, .rejected:
                queueResolutionResult(
                    entry.result,
                    options: MetadataPersistenceOptions(
                        sourceKind: .batchIdentifier,
                        originalInput: entry.input
                    ),
                    successMessage: String(localized: "Queued for review", bundle: .module)
                )
            }
            return
        }

        let context = MetadataImportReviewContext(
            database: viewModel.db,
            resolver: metadataResolver,
            entries: entries
        )
        importReviewSession = ImportReviewSession(
            title: String(localized: "Review identifier import", bundle: .module),
            context: context
        )
    }

    private func prepareStandardReferenceImport(
        from url: URL,
        format: StandardReferenceImportFormat
    ) {
        viewModel.isImporting = true
        viewModel.importProgress = String(localized: "Reading file…", bundle: .module)

        Task { @MainActor in
            do {
                viewModel.importProgress = format.parsingProgress
                let entries = try await format.prepare(from: url)

                guard entries.count > 1 else {
                    let fmt = String(localized: "Importing %d entries…", bundle: .module)
                    viewModel.importProgress = String(format: fmt, entries.count)
                    let database = viewModel.db
                    let references = entries.map(\.reference)
                    let result = try await Task.detached(priority: .userInitiated) {
                        try database.batchImportReferences(
                            references,
                            mergePolicy: .standard
                        )
                    }.value
                    finishStandardReferenceImport(count: result.count)
                    return
                }

                viewModel.isImporting = false
                viewModel.importProgress = nil
                let context = ReferenceImportReviewContext(
                    database: viewModel.db,
                    entries: entries,
                    mergePolicy: .standard
                )
                importReviewSession = ImportReviewSession(
                    title: format.reviewTitle,
                    context: context
                )
            } catch {
                let fmt = String(localized: "content.import.error.generic", bundle: .module)
                viewModel.importProgress = String(format: fmt, error.localizedDescription)
                viewModel.isImporting = false
            }
        }
    }

    private func finishStandardReferenceImport(count: Int) {
        let fmt = String(localized: "Imported %d entries", bundle: .module)
        viewModel.importProgress = String(format: fmt, count)
        viewModel.isImporting = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            viewModel.importProgress = nil
        }
    }

    private func prepareZoteroLibraryImport(_ request: ZoteroLibraryImportRequest) {
        guard !viewModel.isImporting else { return }
        viewModel.isImporting = true
        viewModel.importProgress = String(localized: "Reading Zotero library…", bundle: .module)
        let database = viewModel.db

        Task { @MainActor in
            do {
                let plan = try await ZoteroLibraryImporter.prepare(
                    scope: request.scope,
                    collections: request.collections,
                    includeSubcollections: request.includeSubcollections,
                    includeAnnotations: request.includeAnnotations,
                    db: database,
                    propertyTarget: request.propertyTarget
                )
                try await continueZoteroImport(plan: plan, database: database)
            } catch {
                failZoteroImport(error)
            }
        }
    }

    @MainActor
    private func continueZoteroImport(
        plan: ZoteroFolderImportPlan,
        database: AppDatabase
    ) async throws {
        if ZoteroImportReviewPresentation.shouldReview(entryCount: plan.entries.count) {
            viewModel.isImporting = false
            viewModel.importProgress = nil
            importReviewSession = ImportReviewSession(
                title: String(localized: "Review Zotero Import", bundle: .module),
                context: ZoteroImportReviewContext(
                    database: database,
                    plan: plan,
                    onCompleted: { result in finishZoteroFolderImport(result) }
                )
            )
            return
        }

        let selectedIDs = Set(plan.entries.map(\.id))
        let result = try await Task.detached(priority: .userInitiated) {
            try ZoteroFolderImporter.commit(
                plan: plan,
                selectedEntryIDs: selectedIDs,
                db: database
            )
        }.value
        finishZoteroFolderImport(result)
    }

    private func failZoteroImport(_ error: Error) {
        let fmt = String(localized: "content.import.error.generic", bundle: .module)
        viewModel.importProgress = String(format: fmt, error.localizedDescription)
        viewModel.isImporting = false
    }

    private func finishZoteroFolderImport(_ result: ZoteroFolderImporter.Result) {
        let fmt = String(localized: "Imported %d entries", bundle: .module)
        var message = String(format: fmt, result.imported)
        if result.attached > 0 {
            message += " • \(result.attached) PDF\(result.attached == 1 ? "" : "s") attached"
        }
        if !result.missingPDFs.isEmpty {
            message += " • \(result.missingPDFs.count) missing"
        }
        if result.annotationsImported > 0 {
            message += " • \(result.annotationsImported) annotation\(result.annotationsImported == 1 ? "" : "s") imported"
        }
        if result.annotationsSkipped > 0 {
            message += " • \(result.annotationsSkipped) annotation\(result.annotationsSkipped == 1 ? "" : "s") skipped"
        }
        viewModel.importProgress = message
        viewModel.isImporting = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            viewModel.importProgress = nil
        }
    }

    /// Batch coordinator for materialized PDF/Markdown sources. It owns every
    /// `isImporting`/`importProgress` mutation for the whole batch; the sheet
    /// owns only source acquisition and temporary-file creation.
    private func importFilesWithMetadata(_ sources: [MaterializedImportSource]) {
        guard !sources.isEmpty else { return }
        // A source sheet can finish acquisition just as another import starts.
        // Do not strand its remote temporary directories if that race occurs.
        guard !viewModel.isImporting else {
            sources.forEach { $0.cleanup() }
            return
        }

        if FileImportReviewPresentation.shouldReview(
            requestedSourceCount: sources.count,
            preparedItemCount: sources.count
        ) {
            prepareFileImportReview(sources)
            return
        }

        importFilesImmediately(sources)
    }

    private func prepareFileImportReview(_ sources: [MaterializedImportSource]) {
        let markdownSources = sources.filter { $0.kind == .markdown }
        let pdfSources = sources.filter { $0.kind == .pdf }

        viewModel.isImporting = true
        viewModel.importProgress = String(localized: "Reading file…", bundle: .module)

        Task { @MainActor in
            let markdownPreparation = await prepareMarkdownSources(markdownSources)
            var preparedPDFs: [PDFImportReviewContext.Entry] = []
            for (index, source) in pdfSources.enumerated() {
                if pdfSources.count > 1 {
                    viewModel.importProgress = "\(source.fileURL.lastPathComponent) (\(index + 1)/\(pdfSources.count))…"
                }
                let prepared = await PDFImportCoordinator.preparePDF(
                    from: source.fileURL,
                    resolver: { [metadataResolver] url, extracted in
                        await metadataResolver.resolveImportedPDF(url: url, extracted: extracted)
                    }
                )
                preparedPDFs.append((prepared: prepared, source: source))
            }

            var children: [any ImportReviewContext] = []
            if !markdownPreparation.entries.isEmpty || !markdownPreparation.unreadableSources.isEmpty {
                children.append(
                    MarkdownImportReviewContext(
                        database: viewModel.db,
                        entries: markdownPreparation.entries,
                        sourcesByEntryID: markdownPreparation.sourcesByEntryID,
                        unreadableSources: markdownPreparation.unreadableSources
                    )
                )
            }

            if !preparedPDFs.isEmpty {
                children.append(
                    PDFImportReviewContext(
                        database: viewModel.db,
                        entries: preparedPDFs,
                        resolver: metadataResolver,
                        onImported: { reference in
                            selectedId = reference.id
                            let coordinator = syncCoordinator
                            Task { await coordinator?.kickPDFUploadDrainer() }
                        }
                    )
                )
            }

            let context = CompositeImportReviewContext(children: children)
            viewModel.isImporting = false
            viewModel.importProgress = nil
            importReviewSession = ImportReviewSession(
                title: String(localized: "Review file import", bundle: .module),
                context: context
            )
        }
    }

    private func importFilesImmediately(_ sources: [MaterializedImportSource]) {

        let markdownSources = sources.filter { $0.kind == .markdown }
        let pdfSources = sources.filter { $0.kind == .pdf }

        // Claim a fresh generation so this batch's auto-clear timer only wipes
        // its own summary (see the closure at the end of the Task).
        importGeneration += 1
        let generation = importGeneration
        viewModel.isImporting = true
        // "Importing PDF…" is wrong for an all-markdown batch.
        viewModel.importProgress = pdfSources.isEmpty
            ? String(localized: "Importing markdown…", bundle: .module)
            : String(localized: "content.import.progress.importingPDF", bundle: .module)

        Task { @MainActor in
            // Remote materialization is caller-cleanable; local files have no
            // temporary directory, so cleanup can never delete caller-owned data.
            defer { sources.forEach { $0.cleanup() } }

            var summary: [String] = []
            var queuedIntakes: [MetadataIntake] = []

            // Markdown: validated by ImportSourceMaterializer, then prepared
            // without side effects before the existing fill-only commit.
            if !markdownSources.isEmpty {
                let preparation = await prepareMarkdownSources(markdownSources)
                if !preparation.entries.isEmpty {
                    do {
                        let database = viewModel.db
                        let references = preparation.entries.map(\.reference)
                        let result = try await Task.detached(priority: .userInitiated) {
                            try database.batchImportReferences(
                                references,
                                mergePolicy: .markdownFillOnly
                            )
                        }.value
                        selectedId = result.ids.last
                        let fmt = String(localized: "Imported %d markdown file(s)", bundle: .module)
                        summary.append(String(format: fmt, result.count))
                    } catch {
                        summary.append("Markdown import failed: \(error.localizedDescription)")
                    }
                    // No explicit reload: the list refreshes via observation,
                    // same as standard reference imports.
                }
                if !preparation.unreadableFilenames.isEmpty {
                    summary.append(
                        String(format: String(localized: "Could not read: %@", bundle: .module),
                               preparation.unreadableFilenames.joined(separator: ", "))
                    )
                }
            }

            // PDFs: sequential, one shared metadata-resolution/persistence
            // operation at a time. The coordinator owns durable PDF cleanup.
            for (index, source) in pdfSources.enumerated() {
                let url = source.fileURL
                if pdfSources.count > 1 {
                    viewModel.importProgress = "\(url.lastPathComponent) (\(index + 1)/\(pdfSources.count))…"
                }
                let accessing = source.temporaryDirectoryURL == nil
                    ? url.startAccessingSecurityScopedResource()
                    : false
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                switch await importSinglePDF(source: source) {
                case .imported(let title):
                    let fmt = String(localized: "Imported: %@", bundle: .module)
                    summary.append(String(format: fmt, title))
                case .queued(let intake):
                    queuedIntakes.append(intake)
                    summary.append(String(localized: "Couldn't auto-verify — review metadata to finish", bundle: .module))
                case .failed(let message):
                    summary.append(message)
                }
            }

            viewModel.isImporting = false
            viewModel.importProgress = summary.isEmpty ? nil : summary.joined(separator: " · ")
            if !queuedIntakes.isEmpty {
                scopedPendingMetadataIntakes = PendingMetadataIntakePresentation.scopedIntakes(
                    from: queuedIntakes
                )
                pendingQueueNotice = nil
                showPendingMetadataQueue = true
            }
            // Auto-clear the toast like the standard reference imports do.
            // Only clear if this is still the latest batch — a newer batch bumps
            // importGeneration, so a stale timer here becomes a no-op and can't
            // wipe the newer batch's summary.
            if !summary.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if generation == importGeneration && !viewModel.isImporting {
                        viewModel.importProgress = nil
                    }
                }
            }
        }
    }

    /// Security-scoped URLs must remain accessible while the detached worker
    /// reads them. Both acquisition and release occur on the main actor.
    @MainActor
    private func prepareMarkdownSources(
        _ sources: [MaterializedImportSource]
    ) async -> MarkdownImportPreparationResult {
        var securityScopedURLs: [URL] = []
        for source in sources where source.temporaryDirectoryURL == nil {
            let url = source.fileURL
            if url.startAccessingSecurityScopedResource() {
                securityScopedURLs.append(url)
            }
        }
        defer {
            securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        return await MarkdownImportWorker.prepareSources(sources)
    }

    /// Uses the shared PDF coordinator for resolution and persistence, then
    /// performs only UI-facing follow-through for the batch summary.
    private func importSinglePDF(source: MaterializedImportSource) async -> PDFBatchImportOutcome {
        do {
            switch try await PDFImportCoordinator.importPDF(
                from: source.fileURL,
                database: viewModel.db
            ) {
            case .imported(let reference):
                selectedId = reference.id
                let coordinator = syncCoordinator
                Task { await coordinator?.kickPDFUploadDrainer() }
                return .imported(title: reference.title)
            case .queued(let intake):
                return .queued(intake)
            }
        } catch {
            let fmt = String(localized: "PDF import failed: %@", bundle: .module)
            return .failed(String(format: fmt, error.localizedDescription))
        }
    }

    private func refreshMetadata(for references: [Reference]) {
        let candidates = references.compactMap { reference -> Reference? in
            guard reference.id != nil else { return nil }
            return reference
        }
        guard !candidates.isEmpty else { return }

        if candidates.count == 1, let reference = candidates.first {
            refreshSingleReferenceMetadata(reference)
        } else {
            refreshBatchMetadata(for: candidates)
        }
    }

    private func refreshSingleReferenceMetadata(_ reference: Reference) {
        viewModel.isImporting = true
        viewModel.importProgress = String(localized: "Refreshing metadata…", bundle: .module)

        Task { @MainActor in
            let result = await metadataResolver.refreshReference(reference, allowCandidateSelection: true)
            switch result {
            case .refreshed(let refreshed):
                let fmt = String(localized: "Refreshed: %@", bundle: .module)
                saveRefreshedReference(refreshed, message: String(format: fmt, refreshed.title))

            case .pending(let pendingResult):
                _ = queueResolutionResult(
                    pendingResult,
                    options: MetadataPersistenceOptions(
                        sourceKind: .refresh,
                        originalInput: reference.doi ?? reference.pmid ?? reference.isbn ?? reference.title,
                        linkedReferenceId: reference.id
                    ),
                    successMessage: String(localized: "Queued for review", bundle: .module)
                )

            case .skipped(let reason):
                viewModel.isImporting = false
                viewModel.importProgress = reason
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if !viewModel.isImporting {
                        viewModel.importProgress = nil
                    }
                }

            case .failed(let message):
                viewModel.isImporting = false
                viewModel.importProgress = nil
                viewModel.errorMessage = message
            }
        }
    }

    private func refreshBatchMetadata(for references: [Reference]) {
        viewModel.isImporting = true
        let fmt = String(localized: "Preparing to refresh %d references…", bundle: .module)
        viewModel.importProgress = String(format: fmt, references.count)

        Task { @MainActor in
            var refreshedCount = 0
            var skippedCount = 0
            var failedMessages: [String] = []
            let total = references.count
            let maxConcurrency = 3

            // Process in concurrent batches to improve performance while
            // limiting parallelism to avoid API rate-limiting.
            for batchStart in stride(from: 0, to: total, by: maxConcurrency) {
                let batchEnd = min(batchStart + maxConcurrency, total)
                let batch = Array(references[batchStart..<batchEnd])

                let progressFmt = String(localized: "Refreshing %d–%d of %d…", bundle: .module)
                viewModel.importProgress = String(format: progressFmt, batchStart + 1, batchEnd, total)

                let batchResults: [(Reference, ReferenceMetadataRefreshResult)] = await withTaskGroup(
                    of: (Reference, ReferenceMetadataRefreshResult).self,
                    returning: [(Reference, ReferenceMetadataRefreshResult)].self
                ) { group in
                    for reference in batch {
                        group.addTask {
                            let result = await metadataResolver.refreshReference(reference, allowCandidateSelection: false)
                            return (reference, result)
                        }
                    }
                    var results: [(Reference, ReferenceMetadataRefreshResult)] = []
                    for await pair in group {
                        results.append(pair)
                    }
                    return results
                }

                for (reference, result) in batchResults {
                    switch result {
                    case .refreshed(let refreshed):
                        saveRefreshedReference(refreshed, message: nil, finishRefreshing: false, clearProgress: false)
                        refreshedCount += 1
                    case .pending(let pendingResult):
                        _ = queueResolutionResult(
                            pendingResult,
                            options: MetadataPersistenceOptions(
                                sourceKind: .refresh,
                                originalInput: reference.doi ?? reference.pmid ?? reference.isbn ?? reference.title,
                                linkedReferenceId: reference.id
                            ),
                            successMessage: nil
                        )
                        skippedCount += 1
                    case .skipped:
                        skippedCount += 1
                    case .failed(let message):
                        failedMessages.append("\(reference.title): \(message)")
                    }
                }
            }

            viewModel.isImporting = false
            let summaryFmt = String(localized: "Batch refresh complete: %d updated, %d skipped, %d failed", bundle: .module)
            viewModel.importProgress = String(format: summaryFmt, refreshedCount, skippedCount, failedMessages.count)

            if !failedMessages.isEmpty {
                viewModel.errorMessage = failedMessages.prefix(5).joined(separator: "\n")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !viewModel.isImporting {
                    viewModel.importProgress = nil
                }
            }
        }
    }

    private func saveRefreshedReference(
        _ reference: Reference,
        message: String?,
        finishRefreshing: Bool = true,
        clearProgress: Bool = true
    ) {
        var mutable = reference
        viewModel.saveReference(&mutable)
        viewModel.isImporting = !finishRefreshing ? viewModel.isImporting : false
        viewModel.importProgress = message

        guard clearProgress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !viewModel.isImporting {
                viewModel.importProgress = nil
            }
        }
    }

    @discardableResult
    private func queueResolutionResult(
        _ result: MetadataResolutionResult,
        options: MetadataPersistenceOptions,
        successMessage: String?
    ) -> MetadataPersistenceResult? {
        let persisted = viewModel.persistMetadataResolution(result, options: options)
        switch persisted {
        case .verified(let reference):
            selectedId = reference.id
            viewModel.isImporting = false
            let verifiedFmt = String(localized: "Verified: %@", bundle: .module)
            viewModel.importProgress = successMessage ?? String(format: verifiedFmt, reference.title)
            pendingQueueNotice = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if !viewModel.isImporting {
                    viewModel.importProgress = nil
                }
            }
        case .intake(let intake):
            viewModel.isImporting = false
            viewModel.importProgress = nil
            showPendingQueueNotice(for: intake, message: successMessage)
        case .none:
            viewModel.isImporting = false
            viewModel.importProgress = nil
        }

        return persisted
    }

    private func showPendingQueueNotice(for intake: MetadataIntake, message: String?) {
        let title = String(localized: "This metadata needs your review", bundle: .module)
        let lead: String
        if intake.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lead = String(localized: "The entry", bundle: .module)
        } else {
            lead = "“\(intake.title)”"
        }
        let detail = message?.rubien_nilIfBlank
            ?? intake.statusMessage?.rubien_nilIfBlank
            ?? String(localized: "is waiting in the pending queue.", bundle: .module)

        let bodyFmt = String(localized: "%@ %@ Open the queue to continue.", bundle: .module)
        let notice = PendingQueueNotice(
            title: title,
            message: String(format: bodyFmt, lead, detail)
        )
        pendingQueueNotice = notice

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if pendingQueueNotice?.id == notice.id {
                pendingQueueNotice = nil
            }
        }
    }

    private func deleteReferences(_ references: [Reference]) {
        let ids = references.compactMap(\.id)
        if let selectedId, ids.contains(selectedId) {
            self.selectedId = nil
        }
        viewModel.deleteReferences(references)
    }

    private func openReader(for referenceID: Int64) {
        guard let reference = try? viewModel.db.fetchReferences(ids: [referenceID]).first else { return }
        openReader(for: reference)
    }

    private func openReader(for reference: Reference) {
        if reference.hasPDFInCache(in: viewModel.db) {
            ReaderWindowManager.shared.openPDFReader(for: reference, db: viewModel.db)
        } else if reference.canOpenWebReader {
            ReaderWindowManager.shared.openWebReader(for: reference, db: viewModel.db)
        } else {
            revealReference(reference)
        }
    }

    private func beginSuggestedReferenceImport(_ urlString: String) {
        guard ChatExternalLink.classify(urlString) != .reject else { return }
        suggestedReferenceImport = SuggestedReferenceImport(url: urlString)
    }

    private func finishDeferredReferenceImport() {
        guard let sources = addReferenceFileHandoff.takeAfterDismiss() else { return }
        importFilesWithMetadata(sources)
    }

    private func addReferenceFlowSheet(initialInput: String = "") -> some View {
        AddReferenceFlowSheet(
            initialInput: initialInput,
            allowsFileImports: !viewModel.isImporting,
            resolver: metadataResolver,
            onSaveMetadata: { ref, downloadPDF, pdfURLOverride in
                var r = ref
                let result = viewModel.saveReference(&r)
                if downloadPDF, result != nil, let id = r.id {
                    pdfDownloadCoordinator.download(
                        reference: r,
                        referenceID: id,
                        pdfURLOverride: pdfURLOverride
                    )
                }
                confirmAndReveal(r, result: result)
            },
            onQueueMetadata: { result, input in
                queueResolutionResult(
                    result,
                    options: MetadataPersistenceOptions(
                        sourceKind: .manualEntry,
                        originalInput: input
                    ),
                    successMessage: String(localized: "Queued for review", bundle: .module)
                )
            },
            onSaveWebsite: saveReviewedWebsite,
            onFiles: { sources in
                addReferenceFileHandoff.stage(sources)
            }
        )
    }

    private func saveReviewedWebsite(_ reference: Reference) {
        var saved = reference
        let result = viewModel.saveManualReference(&saved, reviewedBy: "web-import")
        confirmAndReveal(saved, result: result)
    }

    private func showLibrary(
        selecting item: SidebarItem? = nil,
        preemptsInitialDefaultView: Bool = false
    ) {
        let returningFromHome = mainDestination != .library
        if let item {
            viewModel.selectSidebar(
                item,
                stashCurrentDraft: !returningFromHome,
                preemptsInitialDefaultView: preemptsInitialDefaultView
            )
        } else if returningFromHome {
            // Programmatic returns (for example, a clip import) do not flow
            // through the sidebar Binding. Reconcile a saved view whose scope
            // or configuration may have changed through sync while Home was up.
            viewModel.selectSidebar(viewModel.selectedSidebar, stashCurrentDraft: false)
        }
        setMainDestination(.library, mountingLibrary: true)
    }

    private func showHome() {
        setMainDestination(.home)
    }

    /// Destination changes should feel like switching an already-open native
    /// tab. Explicitly suppress transition and NSToolbar diff animations while
    /// batching the retained-surface visibility change with the first mount.
    private func setMainDestination(
        _ destination: MainDestination,
        mountingLibrary: Bool = false
    ) {
        guard mainDestination != destination || (mountingLibrary && !hasPresentedLibrary) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if mountingLibrary { hasPresentedLibrary = true }
            mainDestination = destination
        }
    }

    /// Retained surfaces keep their AppKit controls alive. If navigation was
    /// programmatic, a text editor inside the surface being hidden can still be
    /// the window's first responder; resign only editor responders so a sidebar
    /// click keeps its normal keyboard focus.
    private func resignRetainedDetailEditorIfNeeded() {
        guard let window = hostingWindowBox.window else { return }
        var responder = window.firstResponder
        while let current = responder {
            if current is NSTextView || current is WKWebView {
                window.makeFirstResponder(nil)
                return
            }
            responder = current.nextResponder
        }
    }
}

private extension View {
    /// Keeps an expensive detail surface mounted while making the inactive
    /// destination inert and invisible. This preserves AppKit-backed controls
    /// such as Table and WKWebView across Home/library navigation.
    func retainedDetailSurface(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }
}

private final class HostingWindowBox {
    weak var window: NSWindow?
}

private struct HostingWindowCapture: NSViewRepresentable {
    let box: HostingWindowBox

    func makeNSView(context: Context) -> NSView {
        WindowCaptureView(box: box)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.window = nsView.window
        if let window = nsView.window {
            ContentWindowNotificationRouter.shared.windowAvailable(window)
        }
    }

    private final class WindowCaptureView: NSView {
        weak var box: HostingWindowBox?

        init(box: HostingWindowBox) {
            self.box = box
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
            if let window {
                ContentWindowNotificationRouter.shared.windowAvailable(window)
            }
        }
    }
}

private struct FloatingProgressToast: View {
    let message: String
    let isSpinning: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isSpinning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.85)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        }
        .padding(.top, 10)
        .allowsHitTesting(false)
    }
}

private struct PDFDownloadActivityPanel: View {
    let activities: [PDFDownloadActivity]
    let onRetry: (Int64) -> Void
    let onDismiss: (Int64) -> Void

    var body: some View {
        Group {
            if activities.count > 3 {
                ScrollView {
                    activityRows
                }
                .frame(height: 260)
            } else {
                activityRows
            }
        }
        .frame(width: 340)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
    }

    private var activityRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                if index > 0 {
                    Divider()
                }
                activityRow(activity)
            }
        }
    }

    private func activityRow(_ activity: PDFDownloadActivity) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(for: activity.phase)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(activity.referenceTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                statusText(for: activity.phase)
            }

            Spacer(minLength: 8)

            if case .failed = activity.phase {
                Button(String(localized: "common.retry", bundle: .module)) {
                    onRetry(activity.referenceID)
                }
                .buttonStyle(SLSecondaryButtonStyle())
                .controlSize(.small)
                .accessibilityLabel(String(
                    format: String(localized: "content.pdfDownload.retry.accessibility", bundle: .module),
                    activity.referenceTitle
                ))

                Button {
                    onDismiss(activity.referenceID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "common.close", bundle: .module))
                .accessibilityLabel(String(
                    format: String(localized: "content.pdfDownload.close.accessibility", bundle: .module),
                    activity.referenceTitle
                ))
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusIcon(for phase: PDFDownloadActivity.Phase) -> some View {
        switch phase {
        case .downloading:
            ProgressView()
                .controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusText(for phase: PDFDownloadActivity.Phase) -> some View {
        Group {
            switch phase {
            case .downloading:
                Text(String(localized: "content.pdfDownload.downloading", bundle: .module))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .succeeded:
                Text(String(localized: "content.pdfDownload.succeeded", bundle: .module))
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "content.pdfDownload.failed", bundle: .module))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(message)
                }
            }
        }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

#endif
