#if os(macOS)
import SwiftUI
import Combine
import os
import RubienCore
import RubienPDFKit

private let pdfDownloadLog = Logger(subsystem: "Rubien", category: "pdf-download")

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

@MainActor
final class LibraryViewModel: ObservableObject {
    /// The current page of references returned by the database-level query.
    @Published var references: [Reference] = []
    @Published var pendingMetadataIntakes: [MetadataIntake] = []
    @Published var tags: [Tag] = []
    @Published var selectedSidebar: SidebarItem = .allReferences {
        willSet {
            stashDraftIfDirty(for: selectedSidebar)
        }
        didSet {
            rebuildReferenceObserver()
            syncColumnConfigFromView()
        }
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
    /// Timer-based debounce task for search input.
    private var searchDebounceTask: Task<Void, Never>?
    /// The filter currently applied to the database query.
    private var activeFilter = ReferenceFilter()
    /// Wired up by `ContentView` from its `@EnvironmentObject` so import
    /// flows can kick the PDF upload-queue drainer immediately. Weak to
    /// avoid retain cycles — the coordinator outlives the view model.
    weak var syncCoordinator: SyncCoordinator?

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

    /// Failures are logged silently rather than routed through `errorMessage`, because
    /// that channel drives a modal alert and would interrupt the user after the import
    /// sheet has already dismissed. The work runs detached so the GRDB writer queue
    /// never blocks the main actor.
    ///
    /// `pdfURLOverride` lets the caller (currently Add-by-Identifier) bypass the
    /// arXiv/OpenAlex resolver when the manual-entry resolver already scraped a
    /// PDF URL from the venue page — e.g. OpenReview / CVF / PMLR papers that
    /// have no DOI to feed OpenAlex.
    func downloadPDFInBackground(
        for reference: Reference,
        id: Int64,
        pdfURLOverride: String? = nil
    ) {
        let db = self.db
        let coordinator = self.syncCoordinator
        Task.detached(priority: .userInitiated) {
            do {
                let newPath = try await PDFDownloadService.downloadPDF(
                    for: reference,
                    overrideURL: pdfURLOverride
                )
                try db.attachImportedPDFs(rowIds: [id], filenames: [newPath])
                Task { await coordinator?.kickPDFUploadDrainer() }
            } catch {
                pdfDownloadLog.error("Background PDF download failed: \(error.localizedDescription, privacy: .public)")
            }
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

    func confirmPendingMetadataIntake(_ intake: MetadataIntake, reviewedBy: String = "manual-queue") -> Reference? {
        do {
            return try db.confirmMetadataIntake(intake, reviewedBy: reviewedBy)
        } catch {
            errorMessage = "Manual verification failed: \(error.localizedDescription)"
            return nil
        }
    }

    func deletePendingMetadataIntake(_ intake: MetadataIntake) {
        guard let id = intake.id else { return }
        do {
            try db.deleteMetadataIntake(id: id)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
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
                selectedSidebar = .allReferences
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

    func createDatabaseView(name: String, icon: String = ViewIconCatalog.defaultIcon, scope: ViewScope = .all) {
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
            selectedSidebar = .view(id)
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
        guard let dbView = currentDBView, let id = dbView.id else {
            tableSorts = [.defaultSort]
            viewFilters = []
            viewGroupBy = nil
            viewColumnWraps = []
            return
        }
        if let draft = viewDrafts[id] {
            tableSorts = draft.sorts
            viewFilters = draft.filters
            viewGroupBy = draft.groupBy
            viewColumnWraps = draft.columnWraps
        } else {
            tableSorts = dbView.parsedSorts
            viewFilters = dbView.parsedFilters
            viewGroupBy = dbView.parsedGroupBy
            viewColumnWraps = dbView.parsedColumnWraps
        }
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
        viewFilters = dbView.parsedFilters
        tableSorts = dbView.parsedSorts
        viewGroupBy = dbView.parsedGroupBy
        viewColumnWraps = dbView.parsedColumnWraps
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
            selectedSidebar = .view(id)
        }
    }

    func importBibTeX(from url: URL) {
        isImporting = true
        importProgress = String(localized: "Reading file…", bundle: .module)

        Task.detached { [weak self] in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                await MainActor.run {
                    self.importProgress = String(localized: "Parsing BibTeX…", bundle: .module)
                }

                let refs = BibTeXImporter.parse(content)
                await MainActor.run {
                    let fmt = String(localized: "Importing %d entries…", bundle: .module)
                    self.importProgress = String(format: fmt, refs.count)
                }

                let count = try self.db.batchImportReferences(refs)
                await MainActor.run {
                    let fmt = String(localized: "Imported %d entries", bundle: .module)
                    self.importProgress = String(format: fmt, count)
                    self.isImporting = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.importProgress = nil
                    }
                }
            } catch {
                await MainActor.run {
                    let fmt = String(localized: "content.import.error.generic", bundle: .module)
                    self.importProgress = String(format: fmt, error.localizedDescription)
                    self.isImporting = false
                }
            }
        }
    }

    func importZoteroFolder(from url: URL, target: ZoteroImportPropertyTarget?) {
        isImporting = true
        importProgress = String(localized: "Reading folder…", bundle: .module)

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let result = try ZoteroFolderImporter.importFolder(
                    at: url,
                    db: self.db,
                    propertyTarget: target
                )
                await MainActor.run {
                    let fmt = String(localized: "Imported %d entries", bundle: .module)
                    var msg = String(format: fmt, result.imported)
                    if result.attached > 0 {
                        msg += " • \(result.attached) PDF\(result.attached == 1 ? "" : "s") attached"
                    }
                    if !result.missingPDFs.isEmpty {
                        msg += " • \(result.missingPDFs.count) missing"
                    }
                    self.importProgress = msg
                    self.isImporting = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.importProgress = nil
                    }
                }
            } catch {
                await MainActor.run {
                    let fmt = String(localized: "content.import.error.generic", bundle: .module)
                    self.importProgress = String(format: fmt, error.localizedDescription)
                    self.isImporting = false
                }
            }
        }
    }

    func importRIS(from url: URL) {
        isImporting = true
        importProgress = String(localized: "Reading file…", bundle: .module)

        Task.detached { [weak self] in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                await MainActor.run {
                    self.importProgress = String(localized: "Parsing RIS…", bundle: .module)
                }

                let refs = RISImporter.parse(content)
                await MainActor.run {
                    let fmt = String(localized: "Importing %d entries…", bundle: .module)
                    self.importProgress = String(format: fmt, refs.count)
                }

                let count = try self.db.batchImportReferences(refs)
                await MainActor.run {
                    let fmt = String(localized: "Imported %d entries", bundle: .module)
                    self.importProgress = String(format: fmt, count)
                    self.isImporting = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.importProgress = nil
                    }
                }
            } catch {
                await MainActor.run {
                    let fmt = String(localized: "content.import.error.generic", bundle: .module)
                    self.importProgress = String(format: fmt, error.localizedDescription)
                    self.isImporting = false
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = LibraryViewModel()
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
    @State private var showWebImport = false
    @State private var showAddByIdentifier = false
    @State private var showBatchImport = false
    @State private var pendingZoteroImportFolder: PendingZoteroImport?
    @State private var showPendingMetadataQueue = false
    @State private var pendingQueueNotice: PendingQueueNotice?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedId: Int64?
    @State private var tableScrollRequest = 0
    @State private var columnConfigs: [ColumnConfig] = {
        guard let data = UserDefaults.standard.data(forKey: RubienPreferences.columnConfigsKey),
              let decoded = try? JSONDecoder().decode([ColumnConfig].self, from: data) else {
            return ColumnConfig.defaultColumns
        }
        return decoded
    }()

    private struct PendingQueueNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private struct PendingZoteroImport: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var metadataResolver: MetadataResolver {
        MetadataResolver()
    }

    private var selectedReference: Reference? {
        guard let selectedId else { return nil }
        return viewModel.filteredReferences.first { $0.id == selectedId }
    }

    /// The leading toolbar's flat buttons, in order: Properties, Search, the
    /// add/import actions, then the More-import menu. Rendered with
    /// `ToolbarHoverButtonStyle` (no glass capsule, just a light hover) and a
    /// shared `.titleAndIcon` label style. The enclosing `ToolbarItemGroup` opts
    /// out of the macOS 26 shared glass platter so these stay flat.
    @ViewBuilder
    private var leadingToolbarButtons: some View {
        Group {
            Button {
                showPropertyManager.toggle()
            } label: {
                Label("Properties", systemImage: "slider.horizontal.3")
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

            Button {
                showSearch = true
            } label: {
                Label(String(localized: "common.search", bundle: .module), systemImage: "magnifyingglass")
            }
            .help(String(localized: "Search references", bundle: .module))
            .keyboardShortcut("f", modifiers: .command)

            Button {
                showAddByIdentifier = true
            } label: {
                Label(String(localized: "content.toolbar.addByIdentifier", bundle: .module), systemImage: "text.magnifyingglass")
            }
            .help(String(localized: "Paste a paper URL, DOI, or paper title and fetch metadata automatically", bundle: .module))

            Button {
                showWebImport = true
            } label: {
                Label(String(localized: "Add website", bundle: .module), systemImage: "globe")
            }
            .help(String(localized: "Paste a URL and let Rubien clip the title, abstract, and article body", bundle: .module))

            Button {
                importPDFWithMetadata()
            } label: {
                Label(String(localized: "content.toolbar.importPDFAuto", bundle: .module), systemImage: "doc.badge.plus")
            }
            .help(String(localized: "Import PDFs or markdown notes; PDF metadata is auto-filled when possible", bundle: .module))

            if !viewModel.pendingMetadataIntakes.isEmpty {
                Button {
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
                    Button(String(localized: "content.toolbar.importZoteroFolder", bundle: .module)) { pickZoteroFolder() }
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
                selection: $viewModel.selectedSidebar,
                referenceCount: viewModel.references.count,
                onCreateView: { name, icon in viewModel.createDatabaseView(name: name, icon: icon) },
                onDeleteView: { viewModel.deleteDatabaseView(id: $0) },
                onUpdateView: { id, name, icon in viewModel.updateDatabaseView(id: id, name: name, icon: icon) },
                onReorderViews: { viewModel.reorderDatabaseViews($0) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
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
                scrollRequest: tableScrollRequest
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
            ToolbarItem(placement: .primaryAction) { detailsToggleButton }
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
        .sheet(isPresented: $showWebImport) {
            WebImportView(
                onSave: { ref in
                    var r = ref
                    let result = viewModel.saveManualReference(&r, reviewedBy: "web-import")
                    confirmAndReveal(r, result: result)
                }
            )
        }
        .sheet(isPresented: $showBatchImport) {
            BatchImportView(
                resolver: metadataResolver,
                onImport: { refs in
                viewModel.batchImportReferences(refs)
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
        .sheet(item: $pendingZoteroImportFolder) { pending in
            ZoteroImportSheet(
                folderURL: pending.url,
                db: viewModel.db,
                onConfirm: { target in
                    viewModel.importZoteroFolder(from: pending.url, target: target)
                },
                onCancel: {}
            )
        }
        .overlay {
            if showSearch {
                SearchOverlay(
                    db: viewModel.db,
                    scope: viewModel.currentReferenceScope,
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
        .sheet(isPresented: $showAddByIdentifier) {
            AddByIdentifierView(
                resolver: metadataResolver,
                onSave: { ref, downloadPDF, pdfURLOverride in
                    var r = ref
                    let result = viewModel.saveReference(&r)
                    if downloadPDF, result != nil, let id = r.id {
                        viewModel.downloadPDFInBackground(
                            for: r,
                            id: id,
                            pdfURLOverride: pdfURLOverride
                        )
                    }
                    confirmAndReveal(r, result: result)
                },
                onQueueResult: { result, input in
                    queueResolutionResult(
                        result,
                        options: MetadataPersistenceOptions(
                            sourceKind: .manualEntry,
                            originalInput: input
                        ),
                        successMessage: String(localized: "Queued for review", bundle: .module)
                    )
                }
            )
        }
        .sheet(isPresented: $showPendingMetadataQueue) {
            PendingMetadataQueueView(
                intakes: viewModel.pendingMetadataIntakes,
                resolver: metadataResolver,
                onPersistResult: { result, intake in
                    queueResolutionResult(
                        result,
                        options: MetadataPersistenceOptions(
                            sourceKind: intake.sourceKind,
                            originalInput: intake.originalInput,
                            preferredPDFPath: intake.pdfPath,
                            linkedReferenceId: intake.linkedReferenceId,
                            existingIntakeId: intake.id
                        ),
                        successMessage: nil
                    )
                },
                onConfirmManual: { intake in
                    if let reference = viewModel.confirmPendingMetadataIntake(intake) {
                        selectedId = reference.id
                    }
                },
                onDelete: { intake in
                    viewModel.deletePendingMetadataIntake(intake)
                }
            )
        }
        .overlay(alignment: .bottomTrailing) {
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
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pendingQueueNotice)
        .onChange(of: viewModel.references) { _, newRefs in
            guard let selectedId else { return }
            if !newRefs.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: .rubienClipImported)) { note in
            guard let id = note.userInfo?[RubienClipImportedKeys.id] as? Int64 else { return }
            selectedId = id
            columnVisibility = .all
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
        .onChange(of: columnConfigs) { _, newValue in
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: RubienPreferences.columnConfigsKey)
            }
        }
        .onAppear {
            // Hand the sync coordinator to the view model so import flows
            // inside the model can kick the PDF upload-queue drainer.
            viewModel.syncCoordinator = syncCoordinator
        }
    }

    private func importBibTeX() {
        guard let url = OpenPanelPicker.pickBibTeXFile() else { return }
        viewModel.importBibTeX(from: url)
    }

    private func revealReference(_ reference: Reference) {
        guard let id = reference.id else { return }
        // Land on the unfiltered .allReferences scope (which always renders the row) unless we're
        // already there. Never the default database view — its saved filters could hide the row.
        if case .allReferences = viewModel.selectedSidebar {} else {
            viewModel.selectedSidebar = .allReferences
        }
        selectedId = id
        tableScrollRequest += 1
        columnVisibility = .all
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
        viewModel.importRIS(from: url)
    }

    private func pickZoteroFolder() {
        guard let url = OpenPanelPicker.pickZoteroFolder() else { return }
        pendingZoteroImportFolder = PendingZoteroImport(url: url)
    }

    private func importPDFWithMetadata() {
        guard let url = OpenPanelPicker.pickPDFFile() else { return }
        viewModel.isImporting = true
        viewModel.importProgress = String(localized: "content.import.progress.importingPDF", bundle: .module)

        Task { @MainActor in
            do {
                let prepared = try PDFService.prepareImportedPDF(from: url)
                // `prepared.pdfPath` is the bare filename of the freshly copied
                // PDF under `pdfStorageURL`. We carry it through the resolution
                // flow so the eventual save can register a cache row pointing
                // at the file.
                let preparedPDFFilename = prepared.pdfPath
                _ = MetadataResolutionSeed.fromImportedPDF(url: url, extracted: prepared.extracted)

                if let doi = prepared.extracted.doi, !doi.isEmpty {
                    let fmt = String(localized: "content.import.progress.fetchingMetadata", bundle: .module)
                    viewModel.importProgress = String(format: fmt, doi)
                }

                let resolution = await metadataResolver.resolveImportedPDF(url: url, extracted: prepared.extracted)

                switch resolution {
                case .verified(let envelope):
                    let reference = envelope.reference
                    let fmt = String(localized: "Imported: %@", bundle: .module)
                    finishPDFImport(
                        with: reference,
                        pdfFilename: preparedPDFFilename,
                        message: String(format: fmt, reference.title)
                    )

                case .candidate, .blocked, .seedOnly, .rejected:
                    let queued = queueResolutionResult(
                        resolution,
                        options: MetadataPersistenceOptions(
                            sourceKind: .importedPDF,
                            preferredPDFPath: preparedPDFFilename
                        ),
                        successMessage: String(localized: "Couldn't auto-verify — added to the pending queue", bundle: .module)
                    )
                    if queued == nil {
                        PDFService.deletePDF(at: preparedPDFFilename)
                    }
                }
            } catch {
                viewModel.isImporting = false
                viewModel.importProgress = nil
                let fmt = String(localized: "PDF import failed: %@", bundle: .module)
                viewModel.errorMessage = String(format: fmt, error.localizedDescription)
            }
        }
    }

    private func finishPDFImport(with reference: Reference, pdfFilename: String?, message: String?) {
        var mutable = reference
        viewModel.saveReference(&mutable)
        if let pdfFilename, let id = mutable.id {
            do {
                try viewModel.db.attachImportedPDFs(rowIds: [id], filenames: [pdfFilename])
                let coordinator = syncCoordinator
                Task { await coordinator?.kickPDFUploadDrainer() }
            } catch {
                viewModel.errorMessage = "Attach PDF failed: \(error.localizedDescription)"
            }
        }
        selectedId = mutable.id
        viewModel.isImporting = false
        viewModel.importProgress = message

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !viewModel.isImporting {
                viewModel.importProgress = nil
            }
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
        if reference.hasPDFInCache(in: viewModel.db) {
            ReaderWindowManager.shared.openPDFReader(for: reference, db: viewModel.db)
        } else if reference.canOpenWebReader {
            ReaderWindowManager.shared.openWebReader(for: reference, db: viewModel.db)
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

#endif
